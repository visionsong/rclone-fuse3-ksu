#!/system/bin/sh
# Periodic `rclone sync` / `rclone copy` driver, started in the background by
# service.sh and stopped by deleting the pid file.
#
# POSIX sh only: KernelSU runs scripts with BusyBox ash in standalone mode, so
# bash arrays (`args=( $line )`) and `array[@]` are not available.

MODDIR=${0%/*}

set -a
. "$MODDIR/env"
set +a

[ -n "$RCLONESYNC_PID" ] && touch "$RCLONESYNC_PID"

SYNC_LOG="$RCLONE_LOG_DIR/rclone_sync.log"
COPY_LOG="$RCLONE_LOG_DIR/rclone_copy.log"
TASK_COUNT=0

# Run one config line as an rclone subcommand.
#   $1 = subcommand (sync|copy), $2 = config line, $3 = log file
run_task() {
  _cmd=$1
  _line=$2
  _logf=$3

  # shellcheck disable=SC2086
  set -- $_line
  [ $# -gt 0 ] || return 0

  [ -x "$RCLONE_BIN_DIR/rclone" ] || {
    echo "Error: $RCLONE_BIN_DIR/rclone is missing or not executable" >> "$_logf"
    return 1
  }

  # RCLONE_RC would make rclone talk to a running rc server instead of running
  # the command, so it is cleared for one-shot operations.
  unset RCLONE_RC
  # </dev/null: this function runs inside a `while read` loop, so rclone must
  # not be allowed to swallow the config file from stdin.
  nice -n 19 ionice -c3 "$RCLONE_BIN_DIR/rclone" "$_cmd" "$@" < /dev/null >> "$_logf" 2>&1
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    echo "Error: rclone $_cmd failed (exit $_rc) for arguments: $_line" >> "$_logf"
  fi
  return "$_rc"
}

sync_all() {
  TASK_COUNT=0

  if [ -f "$RCLONESYNC_CONF" ]; then
    while read -r line; do
      [ -z "$line" ] && continue
      _trim=${line#"${line%%[![:space:]]*}"}
      case "$_trim" in '#'*) continue ;; esac

      run_task sync "$line" "$SYNC_LOG"
      TASK_COUNT=$((TASK_COUNT + 1))
    done < "$RCLONESYNC_CONF"
  fi

  if [ -f "$RCLONECOPY_CONF" ]; then
    while read -r line; do
      [ -z "$line" ] && continue
      _trim=${line#"${line%%[![:space:]]*}"}
      case "$_trim" in '#'*) continue ;; esac

      run_task copy "$line" "$COPY_LOG"
      TASK_COUNT=$((TASK_COUNT + 1))
    done < "$RCLONECOPY_CONF"
  fi
}

# `true >`, not `: >`: a failed redirect on the special builtin `:` aborts the
# whole shell, which would silently kill the sync loop.
true > "$SYNC_LOG" 2>/dev/null

while [ -f "$RCLONESYNC_PID" ]; do
  sync_all

  if [ "$TASK_COUNT" -eq 0 ]; then
    echo "No sync or copy tasks found in configuration files." >> "$SYNC_LOG"
    rm -f "$RCLONESYNC_PID"
    break
  fi

  sleep "${RCLONE_SYNC_INTERVAL:-180}"
done
