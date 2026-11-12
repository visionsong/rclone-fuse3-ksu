#!/system/bin/sh
# Runs in KernelSU's "late_start service" stage.
#
# Rules this file must obey (violating any of them is how the old Magisk module
# produced a reboot loop on KernelSU):
#   1. Never touch /vendor. Binaries live in the module's own system/bin and are
#      called by absolute path, so nothing depends on the system overlay.
#   2. Never block init. The boot gate is bounded, every wait is overridable,
#      and the actual work is detached into the background.
#   3. Plain POSIX sh. KernelSU uses BusyBox ash in standalone mode.
#
# Note: KernelSU already starts this script with ScriptWait::NoWait, but a
# script that never returns still leaves broken mounts behind, so the bounded
# gate and the background job below are both deliberate.

MODDIR=${0%/*}

# `env` is sourced with allexport so rclone picks the settings up from the
# environment (that is how rclone reads RCLONE_* variables).
set -a
. "$MODDIR/env"
set +a

LOG="$RCLONE_LOG_DIR/rclone-boot.log"
# `true > file`, not `: > file`: `:` is a *special* builtin, so a failed
# redirect kills the whole shell even with `||` attached. `true` does not.
true > "$LOG" 2>/dev/null || LOG="/dev/null"

log_msg() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"
}

log_msg "service.sh started (module: $RCLONEDIR)"

# ---------------------------------------------------------------------------
# Boot gate. Bounded in both count and total time; if the system is not up we
# exit successfully instead of waiting forever or failing loudly.
# ---------------------------------------------------------------------------
boot_gate() {
  tries=${RCLONE_BOOT_WAIT_TRIES:-30}
  interval=${RCLONE_BOOT_WAIT_INTERVAL:-4}
  i=0
  while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
    if [ "$i" -ge "$tries" ]; then
      return 1
    fi
    i=$((i + 1))
    sleep "$interval"
  done
  return 0
}

if ! boot_gate; then
  log_msg "sys.boot_completed never became 1 after ${tries}x${interval}s; skipping this boot (no retry, no hang)"
  exit 0
fi
log_msg "sys.boot_completed=1"

# Cheap, non-blocking cosmetic update: KernelSU's module list reads this file.
if [ -f "$RCLONEPROP" ]; then
  sed -i 's/^description=\(.\{1,4\}| \)\?/description=/' "$RCLONEPROP" 2>/dev/null
fi

# ---------------------------------------------------------------------------
# Network gate. Bounded and best-effort: a missing `ip` binary must not stop
# local remotes from mounting.
# ---------------------------------------------------------------------------
wait_for_net() {
  command -v ip >/dev/null 2>&1 || return 0
  tries=${RCLONE_NET_WAIT_TRIES:-6}
  interval=${RCLONE_NET_WAIT_INTERVAL:-5}
  i=0
  while [ "$i" -lt "$tries" ]; do
    if ip route 2>/dev/null | grep -q '^default'; then
      return 0
    fi
    i=$((i + 1))
    sleep "$interval"
  done
  return 1
}

# ---------------------------------------------------------------------------
# The real work. Detached, so a slow or hung mount can never hold up the boot.
# ---------------------------------------------------------------------------
start_mounts() {
  if ! wait_for_net; then
    log_msg "no default route yet; mounting anyway (rclone will retry per remote)"
  else
    log_msg "network is up"
  fi

  if [ ! -x "$RCLONE_BIN_DIR/rclone" ]; then
    log_msg "ERROR: $RCLONE_BIN_DIR/rclone is missing or not executable"
    return 1
  fi

  # `sed -n 's/:$//p'` only prints lines that end in a colon, so a stray
  # warning on stdout can never be mistaken for a remote name.
  remotes=$("$RCLONE_BIN_DIR/rclone" listremotes 2>>"$LOG" | sed -n 's/:$//p')
  if [ -z "$remotes" ]; then
    log_msg "no remotes configured in $RCLONE_CONFIG"
    return 0
  fi

  printf '%s\n' "$remotes" | while read -r remote; do
    [ -n "$remote" ] || continue
    log_msg "mounting remote: $remote"
    # --daemon hands the mount to a detached process; rclone-mount itself runs
    # rclone in the foreground, so without this the whole loop would block.
    "$RCLONE_BIN_DIR/rclone-mount" "$remote" --daemon >>"$LOG" 2>&1 \
      && log_msg "mount requested: $remote" \
      || log_msg "ERROR: mount failed: $remote"
  done

  if [ -x "$MODDIR/sync.service.sh" ] && { [ -f "$RCLONESYNC_CONF" ] || [ -f "$RCLONECOPY_CONF" ]; }; then
    log_msg "starting sync service"
    # `&` plus setsid-free explicit backgrounding: the loop below re-reads
    # $RCLONESYNC_PID, so the pid file must exist before we return.
    ( nice -n 19 ionice -c3 "$MODDIR/sync.service.sh" >>"$LOG" 2>&1 & echo $! > "$RCLONESYNC_PID" )
  else
    log_msg "no sync/copy config, sync service not started"
  fi
}

(
  start_mounts
  log_msg "background work finished"
) &

log_msg "service.sh returning; mount work detached (pid $!)"
exit 0
