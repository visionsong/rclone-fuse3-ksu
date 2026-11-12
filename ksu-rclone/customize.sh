#!/system/bin/sh
# KernelSU install-time script. `ui_print` and `abort` are provided by ksud's
# installer (userspace/ksud/src/installer.sh).
#
# Notes:
#  * ksud already applies set_perm_recursive to the whole module plus
#    0:2000 0755 for system/bin, so no chmod spiral is needed here.
#  * ksud deletes customize.sh, README.md and .git* after installing.
#  * No SKIPUNZIP is set, so ksud extracts the full zip for us.

MODPATH=${MODPATH:-${0%/*}}

MODULE_CONFIG="/data/adb/modules/rclone/conf"

# Installer-provided helpers may be absent when this file is run by hand.
: "${ui_print:=echo}"

ui_print "- Configuring rclone module"

# Keep the binaries executable in case the zip was unpacked without mode bits.
if [ -d "$MODPATH/system/bin" ]; then
  chmod 0755 "$MODPATH/system/bin/"* 2>/dev/null
fi
for script in service.sh sync.service.sh action.sh; do
  [ -f "$MODPATH/$script" ] && chmod 0755 "$MODPATH/$script" 2>/dev/null
done

# Preserve an existing config across reinstalls.
if [ -d "$MODULE_CONFIG" ]; then
  cp -r "$MODULE_CONFIG" "$MODPATH/" 2>/dev/null
  ui_print "- Existing config restored from $MODULE_CONFIG"
  ui_print "  已检测到配置目录，已保留原有配置"
  sed -i 's/^description=\(.\{1,4\}| \)\?/description=✅| /' "$MODPATH/module.prop" 2>/dev/null
else
  ui_print "- Create your rclone config here:"
  ui_print "    $MODULE_CONFIG/rclone.conf"
  ui_print "    $MODULE_CONFIG/env          (optional overrides)"
  ui_print "    $MODULE_CONFIG/sync         (one '<remote>:<path> <local>' per line)"
  ui_print "    $MODULE_CONFIG/copy         (same format, uses rclone copy)"
  sed -i 's/^description=\(.\{1,4\}| \)\?/description=⚙️| /' "$MODPATH/module.prop" 2>/dev/null
fi

ui_print "- Binaries are in system/bin and are also called by absolute path,"
ui_print "  so the module works with or without meta-overlayfs."
ui_print "- Reboot to activate, or press the Action button for the Web GUI."
ui_print ""
