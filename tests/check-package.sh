#!/system/bin/sh
# Static packaging / schema validator for the rclone KernelSU module.
# Pure POSIX sh: runs on Linux, macOS, Termux, or inside a KSU shell.
#
#   tests/check-package.sh                        # validate the source tree
#   tests/check-package.sh module                 # explicit module directory
#   tests/check-package.sh module out/foo.zip     # also validate a packaged zip
#
# Exit code 0 = everything passed, 1 = at least one FAIL.

set -u

MODULE_DIR=${1:-}
ZIP_FILE=${2:-}

if [ -z "$MODULE_DIR" ]; then
  for d in module ksu-rclone magisk-rclone; do
    if [ -f "$d/module.prop" ]; then MODULE_DIR=$d; break; fi
  done
fi
if [ -z "$MODULE_DIR" ] || [ ! -f "$MODULE_DIR/module.prop" ]; then
  echo "!! cannot find the module directory (expected module/, ksu-rclone/ or magisk-rclone/)" >&2
  exit 1
fi

FAIL=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL + 1)); }
info() { printf '  ..    %s\n' "$1"; }
head2() { printf '\n== %s ==\n' "$1"; }

# ---------------------------------------------------------------------------
head2 "layout (module dir: $MODULE_DIR)"

# Binaries must live in system/bin. system/vendor is only mountable through a
# metamodule and is the exact reason the old module bootlooped.
if [ -d "$MODULE_DIR/system/vendor" ]; then
  bad "system/vendor exists -- must be system/bin (KSU overlay on /vendor is unsafe)"
else
  ok "no system/vendor directory"
fi

if [ -d "$MODULE_DIR/system/bin" ]; then
  ok "system/bin exists"
else
  bad "system/bin is missing"
fi

for f in rclone-config rclone-kill-all rclone-mount rclone-sync rclone-web; do
  if [ -f "$MODULE_DIR/system/bin/$f" ]; then
    ok "system/bin/$f present"
  else
    bad "system/bin/$f missing"
  fi
done

for f in module.prop service.sh sync.service.sh customize.sh action.sh env; do
  if [ -f "$MODULE_DIR/$f" ]; then ok "$f present"; else bad "$f missing"; fi
done

# ---------------------------------------------------------------------------
head2 "module.prop schema"

PROP="$MODULE_DIR/module.prop"

if LC_ALL=C grep -q "$(printf '\r')" "$PROP" 2>/dev/null; then
  bad "module.prop contains CR bytes -- must be pure LF"
else
  ok "module.prop is LF-only"
fi

prop_get() { sed -n "s/^$1=//p" "$PROP" | head -n 1; }

MODID=$(prop_get id)
MODNAME=$(prop_get name)
MODVER=$(prop_get version)
MODVC=$(prop_get versionCode)
MODAUTH=$(prop_get author)

[ -n "$MODID" ]   && ok "id=$MODID"                 || bad "id is empty"
[ -n "$MODNAME" ] && ok "name=$MODNAME"             || bad "name is empty"
[ -n "$MODVER" ]  && ok "version=$MODVER"           || bad "version is empty"
[ -n "$MODAUTH" ] && ok "author=$MODAUTH"           || bad "author is empty"

case "$MODID" in
  [a-zA-Z]*)
    case "$MODID" in
      *[!a-zA-Z0-9._-]*) bad "id '$MODID' violates ^[a-zA-Z][a-zA-Z0-9._-]+$" ;;
      *) ok "id matches ^[a-zA-Z][a-zA-Z0-9._-]+$" ;;
    esac
    ;;
  *) bad "id '$MODID' must start with an ASCII letter" ;;
esac

case "$MODVC" in
  ''|*[!0-9]*) bad "versionCode '$MODVC' is not an integer" ;;
  *) ok "versionCode=$MODVC is an integer" ;;
esac

# The module id is also the conf directory name; renaming it orphans user config.
if [ "$MODID" = "rclone" ]; then
  ok "id stays 'rclone' (keeps /data/adb/modules/rclone/conf discoverable)"
else
  info "id changed to '$MODID' -- README/conf paths must be updated too"
fi

# ---------------------------------------------------------------------------
head2 "shell syntax"

SYNTAX_CHECKER=""
if command -v busybox >/dev/null 2>&1 && busybox ash -c 'echo' >/dev/null 2>&1; then
  SYNTAX_CHECKER="busybox ash"
elif command -v dash >/dev/null 2>&1; then
  SYNTAX_CHECKER="dash"
elif command -v bash >/dev/null 2>&1; then
  SYNTAX_CHECKER="bash"
fi

if [ -z "$SYNTAX_CHECKER" ]; then
  info "no busybox/dash/bash available -- skipped syntax checks"
else
  info "using: $SYNTAX_CHECKER -n"
  for f in "$MODULE_DIR"/*.sh "$MODULE_DIR"/system/bin/*; do
    [ -f "$f" ] || continue
    case "$f" in
      *.prop|*.json|*.conf|*.png) continue ;;
    esac
    if $SYNTAX_CHECKER -n "$f" 2>/dev/null; then
      ok "syntax: ${f#"$MODULE_DIR"/}"
    else
      bad "syntax error: ${f#"$MODULE_DIR"/}"
    fi
  done
fi

# ---------------------------------------------------------------------------
head2 "no Magisk-only leftovers"

# Only look at code that actually runs on the device.
LEFTOVER_FILES="$MODULE_DIR"
# Strip whole-line comments first: a comment explaining "no [[ ]] allowed"
# must not itself be reported as a leftover.
CODE_FILES=$(mktemp -d)
grep -rn '^[[:space:]]*[^[:space:]#]' "$LEFTOVER_FILES" 2>/dev/null > "$CODE_FILES/all.txt"
for pat in 'log -t Magisk' '/vendor/bin/' 'MAGISKTMP' '\[\[ ' 'function [a-z_]*(' ; do
  hits=$(grep -E -- "$pat" "$CODE_FILES/all.txt" 2>/dev/null | grep -v 'Binary file')
  if [ -n "$hits" ]; then
    bad "leftover '$pat':"
    printf '%s\n' "$hits" | sed 's/^/        /'
  else
    ok "no '$pat'"
  fi
done
rm -rf "$CODE_FILES"

# ---------------------------------------------------------------------------
head2 "bootloop-safety invariants"

SERVICE="$MODULE_DIR/service.sh"
if [ -f "$SERVICE" ]; then
  # The gate must come before anything that can block or mount. Comments are
  # stripped first so prose about mounting cannot trigger a false positive.
  CODE=$(grep -vn '^[[:space:]]*#' "$SERVICE")

  GATE_LINE=$(printf '%s\n' "$CODE" | grep 'sys.boot_completed' | head -n 1 | cut -d: -f1)
  FIRST_MOUNT_LINE=$(printf '%s\n' "$CODE" | grep 'rclone-mount\|rclone mount' | head -n 1 | cut -d: -f1)
  if [ -n "$GATE_LINE" ]; then
    ok "service.sh gates on sys.boot_completed (line $GATE_LINE)"
    if [ -n "$FIRST_MOUNT_LINE" ] && [ "$GATE_LINE" -gt "$FIRST_MOUNT_LINE" ]; then
      bad "service.sh mounts (line $FIRST_MOUNT_LINE) before the boot gate (line $GATE_LINE)"
    fi
  else
    bad "service.sh has no sys.boot_completed gate"
  fi

  if grep -q 'while true' "$SERVICE"; then
    bad "service.sh contains an unbounded 'while true' loop"
  else
    ok "no unbounded 'while true' in service.sh"
  fi

  if grep -q 'RCLONE_BOOT_WAIT_TRIES' "$SERVICE"; then
    ok "boot wait is bounded and overridable (RCLONE_BOOT_WAIT_TRIES)"
  else
    bad "boot wait bound is not overridable -- tests cannot compress it"
  fi
fi

# post-fs-data runs while init is still waiting; a block there is a hard bootloop.
if [ -f "$MODULE_DIR/post-fs-data.sh" ]; then
  bad "post-fs-data.sh exists -- init waits for it, keep it absent or non-blocking"
else
  ok "no post-fs-data.sh (nothing blocks init)"
fi

# ---------------------------------------------------------------------------
head2 "update metadata (visionsong/rclone-fuse3-ksu)"

if grep -q 'NewFuture/rclone-fuse3-magisk' "$PROP"; then
  bad "module.prop still points updateJson at the upstream Magisk repo"
else
  ok "module.prop updateJson does not reference the upstream Magisk repo"
fi

if grep -q 'visionsong/rclone-fuse3-ksu' "$PROP"; then
  ok "module.prop updateJson points at visionsong/rclone-fuse3-ksu"
else
  info "module.prop does not reference visionsong/rclone-fuse3-ksu yet"
fi

for j in update-*.json; do
  [ -f "$j" ] || continue
  if command -v python3 >/dev/null 2>&1; then
    if python3 -m json.tool "$j" >/dev/null 2>&1; then ok "valid JSON: $j"; else bad "invalid JSON: $j"; fi
  else
    info "python3 missing -- skipped JSON validation for $j"
  fi
done

# ---------------------------------------------------------------------------
if [ -n "$ZIP_FILE" ]; then
  head2 "packaged zip: $ZIP_FILE"
  if [ ! -f "$ZIP_FILE" ]; then
    bad "zip not found"
  elif ! command -v unzip >/dev/null 2>&1; then
    info "unzip missing -- skipped zip validation"
  else
    LIST=$(unzip -Z1 "$ZIP_FILE" 2>/dev/null)

    if printf '%s\n' "$LIST" | grep -qx 'module.prop'; then
      ok "module.prop sits at the zip root"
    else
      bad "module.prop is not at the zip root (KSU/Magisk refuse to install)"
      info "top-level entries:"
      printf '%s\n' "$LIST" | cut -d/ -f1 | sort -u | sed 's/^/        /'
    fi

    if printf '%s\n' "$LIST" | grep -q '^system/vendor/'; then
      bad "zip ships system/vendor/ -- the /vendor overlay is what bootlooped"
    else
      ok "zip ships no system/vendor/"
    fi

    for f in system/bin/rclone system/bin/fusermount3 \
             system/bin/rclone-mount system/bin/rclone-web \
             service.sh customize.sh action.sh env; do
      if printf '%s\n' "$LIST" | grep -qx "$f"; then ok "zip: $f"; else bad "zip: $f missing"; fi
    done

    if command -v unzip >/dev/null 2>&1; then
      TMPZ=$(mktemp -d 2>/dev/null || echo "/tmp/rclone-zip-$$")
      mkdir -p "$TMPZ"
      unzip -o -q "$ZIP_FILE" -d "$TMPZ" 2>/dev/null
      for f in system/bin/rclone system/bin/fusermount3 service.sh sync.service.sh customize.sh action.sh; do
        if [ -f "$TMPZ/$f" ]; then
          if [ -x "$TMPZ/$f" ]; then ok "zip exec bit: $f"; else bad "zip exec bit missing: $f"; fi
        fi
      done
      rm -rf "$TMPZ"
    fi
  fi
fi

# ---------------------------------------------------------------------------
printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32mALL CHECKS PASSED\033[0m\n'
  exit 0
fi
printf '\033[31m%d CHECK(S) FAILED\033[0m\n' "$FAIL"
exit 1
