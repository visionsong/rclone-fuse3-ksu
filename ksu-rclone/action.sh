#!/system/bin/sh
# KernelSU Action button: toggles the rclone Web GUI.
#
# KernelSU's manager runs this file with BusyBox `ash` (standalone mode), so it
# must be plain POSIX sh -- no `function` keyword, no `[[ ]]`. `rclone-web` is
# called by absolute path so it works with or without a metamodule.

MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/rclone

echo "Loading environment variables"
echo "  * predefined: $MODDIR/env"
set -a
. "$MODDIR/env"
set +a
echo "  * customized: $RCLONE_CONFIG_DIR/env"

# Stop a running Web GUI if the pid file still points at a live process.
# Returns 1 when it stopped something (so the caller flips to "start").
check_stop_web_pid() {
  [ -f "$RCLONEWEB_PID" ] || return 0

  pid=$(cat "$RCLONEWEB_PID" 2>/dev/null)
  if [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1; then
    echo "RClone Web GUI is already running with PID($pid). Stopping it..."
    # The pid is `nohup rclone-web`, a shell wrapper; kill its children first.
    pkill -P "$pid" 2>/dev/null
    kill "$pid" 2>/dev/null
    rm -f "$RCLONEWEB_PID"
    echo "RClone Web GUI stopped."
    echo "已关闭 RClone Web GUI"
    return 1
  fi

  echo "Found a stale PID file. Removing it..."
  rm -f "$RCLONEWEB_PID"
  return 0
}

start_web() {
  case "$RCLONE_RC_ADDR" in
    :*)
      local_ip=$(ip route get 1 2>/dev/null | sed -n 's/^.*src \([0-9.]*\) .*$/\1/p')
      url="http://${local_ip:-localhost}${RCLONE_RC_ADDR}"
      ;;
    *)
      url="$RCLONE_RC_ADDR"
      ;;
  esac

  if [ ! -x "$RCLONE_BIN_DIR/rclone-web" ]; then
    echo "ERROR: $RCLONE_BIN_DIR/rclone-web is missing or not executable"
    return 1
  fi

  echo "RClone Web GUI starting at: $url"
  echo "浏览器访问: $url"

  nohup "$RCLONE_BIN_DIR/rclone-web" > "$RCLONE_LOG_DIR/rclone-web.log" 2>&1 &
  pid=$!
  echo "$pid" > "$RCLONEWEB_PID"
  echo "RClone Web GUI started with PID($pid)."
}

if check_stop_web_pid; then
  start_web
fi
