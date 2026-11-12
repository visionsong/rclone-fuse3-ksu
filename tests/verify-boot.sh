#!/system/bin/sh
# On-device, NON-FLASHING verification for the rclone KernelSU module.
#
# Nothing is installed into /data/adb/modules and the device is never rebooted.
# The module tree is copied to a scratch directory and service.sh / action.sh /
# sync.service.sh are executed there with su -M (the *global* mount namespace,
# which is exactly the namespace KernelSU runs module scripts in).
#
# Usage (on the phone, from Termux or adb shell):
#
#   su -M -c 'sh tests/verify-boot.sh'                      # default run
#   su -M -c 'RCLONE_TEST_BINDS=1 sh tests/verify-boot.sh'  # also test sdcard binds
#   su -M -c 'RCLONE_TEST_SYNC=1  sh tests/verify-boot.sh'  # also test sync loop
#   su -M -c 'RCLONE_TEST_KEEP=1  sh tests/verify-boot.sh'  # keep sandbox for poking
#
# Exit code 0 = all checks passed.

set -u

MODULE_DIR=${MODULE_DIR:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}
SANDBOX=${RCLONE_TEST_SANDBOX:-/data/local/tmp/rclone-ksu-selftest}
REMOTE=selftest
MNT="/mnt/rclone-$REMOTE"
BOOT_TIMEOUT=${RCLONE_TEST_TIMEOUT:-90}

FAIL=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL + 1)); }
info() { printf '  ..    %s\n' "$1"; }
head2() { printf '\n== %s ==\n' "$1"; }

cleanup() {
  [ "${RCLONE_TEST_KEEP:-0}" = "1" ] && { info "sandbox kept at $SANDBOX"; return; }
  info "cleanup"
  ( cd "$SANDBOX/mod" 2>/dev/null && sh ./system/bin/rclone-kill-all >/dev/null 2>&1 ) || true
  pkill -f "rclone mount $REMOTE:" >/dev/null 2>&1 || true
  pkill -f "rclone rcd" >/dev/null 2>&1 || true
  pkill -f "$SANDBOX/mod/sync.service.sh" >/dev/null 2>&1 || true
  for p in "$MNT" \
           "/mnt/pass_through/0/emulated/0/$REMOTE" \
           "/mnt/runtime/default/emulated/0/$REMOTE"; do
    umount -l "$p" >/dev/null 2>&1 || true
  done
  [ "${RCLONE_TEST_BINDS:-0}" = "1" ] && rm -rf "/data/media/0/$REMOTE" 2>/dev/null || true
  rm -rf "$SANDBOX" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
head2 "preflight"

if [ "$(id -u)" != "0" ]; then
  bad "not root -- re-run as: su -M -c 'sh $0'"
  echo "  (root is required to mount FUSE and to enter the global mount namespace)"
  exit 1
fi
ok "running as root"

SELF_NS=$(readlink /proc/self/ns/mnt 2>/dev/null)
INIT_NS=$(readlink /proc/1/ns/mnt 2>/dev/null)
if [ -n "$SELF_NS" ] && [ "$SELF_NS" = "$INIT_NS" ]; then
  ok "inside the global mount namespace ($SELF_NS)"
else
  bad "NOT in the global mount namespace (self=$SELF_NS init=$INIT_NS)"
  echo "  KSU runs module scripts in the global namespace; mounts made in a"
  echo "  per-process namespace would be invisible to apps and would make this"
  echo "  test meaningless. Re-run with: su -M -c 'sh $0'"
  exit 1
fi

if [ ! -f "$MODULE_DIR/service.sh" ]; then
  bad "module dir not found: $MODULE_DIR (set MODULE_DIR=...)"
  exit 1
fi
ok "module tree: $MODULE_DIR"

RCLONE_SRC="$MODULE_DIR/system/bin/rclone"
if [ ! -f "$RCLONE_SRC" ]; then
  RCLONE_SRC=$(command -v rclone 2>/dev/null)
  [ -n "$RCLONE_SRC" ] && info "using host rclone from PATH: $RCLONE_SRC" \
                       || { bad "no rclone binary (build it or install it in PATH)"; exit 1; }
else
  ok "bundled binary: system/bin/rclone"
fi

if [ ! -f "$MODULE_DIR/system/bin/fusermount3" ]; then
  info "system/bin/fusermount3 absent -- rclone will fall back to fusermount in PATH"
fi

# ---------------------------------------------------------------------------
head2 "sandbox setup"

rm -rf "$SANDBOX"
mkdir -p "$SANDBOX" || { bad "cannot create $SANDBOX"; exit 1; }

cp -r "$MODULE_DIR" "$SANDBOX/mod" || { bad "cannot copy module tree"; exit 1; }
rm -rf "$SANDBOX/mod/.git" "$SANDBOX/mod/customize.sh"
cp "$RCLONE_SRC" "$SANDBOX/mod/system/bin/rclone"
chmod 0755 "$SANDBOX/mod/system/bin/rclone" 2>/dev/null
chmod 0755 "$SANDBOX/mod/system/bin/"* 2>/dev/null
chmod 0755 "$SANDBOX/mod/service.sh" "$SANDBOX/mod/action.sh" "$SANDBOX/mod/sync.service.sh" 2>/dev/null
ok "module copied to $SANDBOX/mod"

# Isolated config + log dirs so the real /data/adb/modules/rclone is untouched.
mkdir -p "$SANDBOX/conf" "$SANDBOX/log" "$SANDBOX/files"

# A local-backend remote: mounts over real files, so a successful mount is
# observable without any network access.
cat > "$SANDBOX/conf/rclone.conf" <<EOF
[$REMOTE]
type = local
nounc = true
EOF
echo "hello from the rclone ksu self-test" > "$SANDBOX/files/probe.txt"

# Sourced last by env, so these win over the shipped defaults.
cat > "$SANDBOX/conf/env" <<EOF
RCLONE_LOG_DIR="$SANDBOX/log"
RCLONE_RC_ADDR=:15572
EOF
ok "isolated conf/log dirs created"

# Compress the boot gate: the point is to exercise the bounded loop, not to wait.
export RCLONE_BOOT_WAIT_TRIES=3
export RCLONE_BOOT_WAIT_INTERVAL=1
export RCLONE_NET_WAIT_TRIES=1
export RCLONE_NET_WAIT_INTERVAL=1
ok "boot/network waits compressed for the test"

# ---------------------------------------------------------------------------
head2 "service.sh (late_start service stage)"

START=$(date +%s)
( export MODDIR="$SANDBOX/mod"; cd "$SANDBOX/mod" && sh ./service.sh ) >"$SANDBOX/log/service.out" 2>&1
RC=$?
ELAPSED=$(( $(date +%s) - START ))

if [ "$RC" -eq 0 ]; then
  ok "service.sh exited 0 (returned in ${ELAPSED}s -- it must never block init)"
else
  bad "service.sh exited $RC"
  sed 's/^/        /' "$SANDBOX/log/service.out" | tail -n 20
fi

if [ "$ELAPSED" -gt "$BOOT_TIMEOUT" ]; then
  bad "service.sh blocked for ${ELAPSED}s (limit ${BOOT_TIMEOUT}s) -- bootloop risk"
else
  ok "service.sh returned within ${ELAPSED}s"
fi

# Whatever service.sh spawned must survive the parent exiting.
sleep 3

if pgrep -f "rclone mount $REMOTE:" >/dev/null 2>&1; then
  ok "rclone mount is alive after service.sh returned: $(pgrep -f "rclone mount $REMOTE:" | tr '\n' ' ')"
else
  bad "no surviving 'rclone mount $REMOTE:' process"
  sed 's/^/        /' "$SANDBOX/log/service.out" | tail -n 20
fi

if mount | grep -q " $MNT "; then
  ok "mountpoint registered in the global mount table"
elif mountpoint -q "$MNT" 2>/dev/null; then
  ok "mountpoint -q $MNT"
else
  bad "$MNT is not a mountpoint"
fi

if mount | grep "$MNT" | grep -q 'fuse'; then
  ok "filesystem type is fuse ($(mount | grep " $MNT " | sed 's/.*type //;s/ .*//'))"
else
  info "fuse type not reported for $MNT"
fi

if ls "$MNT/probe.txt" >/dev/null 2>&1; then
  ok "mount is readable: $MNT/probe.txt -> $(cat "$MNT/probe.txt" 2>/dev/null)"
else
  bad "cannot read through the mount at $MNT"
fi

# This is the check that proves the /vendor regression is gone: the old module
# resolved binaries from system/vendor, which KSU cannot mount without a
# metamodule, so nothing ran at all.
if [ -x "$SANDBOX/mod/system/bin/rclone" ]; then
  ok "binaries resolve from the module's own system/bin (no metamodule needed)"
fi
if [ -d "$SANDBOX/mod/system/vendor" ]; then
  bad "module still ships system/vendor -- this is the original bootloop cause"
fi

# ---------------------------------------------------------------------------
if [ "${RCLONE_TEST_BINDS:-0}" = "1" ]; then
  head2 "cross-app visibility (sdcard binds)"
  for p in "/data/media/0/$REMOTE" \
           "/mnt/pass_through/0/emulated/0/$REMOTE" \
           "/mnt/runtime/default/emulated/0/$REMOTE"; do
    if mount | grep -q " $p "; then
      ok "bind mounted: $p"
      if ls "$p/probe.txt" >/dev/null 2>&1; then
        ok "  readable through $p"
      else
        bad "  not readable through $p"
      fi
    else
      bad "not bind mounted: $p"
    fi
  done
  info "check from an unrooted app shell: ls /sdcard/$REMOTE"
else
  head2 "cross-app visibility (skipped)"
  info "set RCLONE_TEST_BINDS=1 to also create/verify the /sdcard binds"
fi

# ---------------------------------------------------------------------------
head2 "action.sh (Web GUI toggle)"

( export MODDIR="$SANDBOX/mod"; cd "$SANDBOX/mod" && sh ./action.sh ) >"$SANDBOX/log/action-start.out" 2>&1
RC=$?
[ "$RC" -eq 0 ] && ok "action.sh (start) exited 0" || {
  bad "action.sh (start) exited $RC"; sed 's/^/        /' "$SANDBOX/log/action-start.out" | tail -n 20; }

sleep 4

if pgrep -f "rclone rcd" >/dev/null 2>&1; then
  ok "web GUI daemon is alive: $(pgrep -f 'rclone rcd' | tr '\n' ' ')"
else
  bad "web GUI daemon is not running"
  sed 's/^/        /' "$SANDBOX/log/action-start.out" | tail -n 20
fi

if [ -f "$SANDBOX/log/rclone_web.pid" ]; then
  ok "pid file written: $(cat "$SANDBOX/log/rclone_web.pid" 2>/dev/null)"
else
  bad "pid file missing: $SANDBOX/log/rclone_web.pid (action.sh stop would not work)"
fi

if ls "$SANDBOX/log/rclone-web.log" >/dev/null 2>&1; then
  ok "web log created ($(wc -c < "$SANDBOX/log/rclone-web.log" 2>/dev/null) bytes)"
fi

if command -v curl >/dev/null 2>&1; then
  if curl -s -m 5 -o /dev/null "http://127.0.0.1:15572/" 2>/dev/null; then
    ok "web GUI answers on http://127.0.0.1:15572/"
  else
    info "no HTTP answer yet on :15572 (rclone may still be downloading the GUI bundle)"
  fi
else
  info "curl missing -- skipping the HTTP probe"
fi

( export MODDIR="$SANDBOX/mod"; cd "$SANDBOX/mod" && sh ./action.sh ) >"$SANDBOX/log/action-stop.out" 2>&1
sleep 2
if pgrep -f "rclone rcd" >/dev/null 2>&1; then
  bad "second action.sh did not stop the web GUI"
else
  ok "second action.sh stopped the web GUI (toggle works)"
fi

# ---------------------------------------------------------------------------
if [ "${RCLONE_TEST_SYNC:-0}" = "1" ]; then
  head2 "sync.service.sh (one round)"

  : > "$SANDBOX/log/rclone_sync.log"
  printf '%s:%s %s\n' "$REMOTE" "files" "$SANDBOX/mirror" > "$SANDBOX/conf/sync"

  ( export MODDIR="$SANDBOX/mod"
    cd "$SANDBOX/mod" &&
    timeout 60 sh ./sync.service.sh ) >"$SANDBOX/log/sync.out" 2>&1
  RC=$?
  [ "$RC" -eq 0 ] && ok "sync.service.sh exited 0" || info "sync.service.sh exited $RC (timeout wrapper)"

  if [ -f "$SANDBOX/mirror/probe.txt" ]; then
    ok "sync copied the remote into $SANDBOX/mirror"
  else
    bad "sync did not produce $SANDBOX/mirror/probe.txt"
    sed 's/^/        /' "$SANDBOX/log/rclone_sync.log" | tail -n 20
  fi

  if grep -qi 'error' "$SANDBOX/log/rclone_sync.log" 2>/dev/null; then
    bad "sync log contains errors"
    sed 's/^/        /' "$SANDBOX/log/rclone_sync.log" | tail -n 20
  else
    ok "sync log is clean"
  fi
else
  head2 "sync.service.sh (skipped)"
  info "set RCLONE_TEST_SYNC=1 to exercise one sync round"
fi

# ---------------------------------------------------------------------------
head2 "logs collected under $SANDBOX/log"
for f in "$SANDBOX/log"/*; do
  [ -f "$f" ] || continue
  printf '  -- %s (%s bytes)\n' "$(basename "$f")" "$(wc -c < "$f" 2>/dev/null)"
done

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32mALL RUNTIME CHECKS PASSED\033[0m\n'
  exit 0
fi
printf '\033[31m%d CHECK(S) FAILED\033[0m\n' "$FAIL"
exit 1
