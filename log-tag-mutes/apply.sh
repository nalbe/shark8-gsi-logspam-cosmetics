#!/system/bin/sh
# log-tag-mutes: install the module and set the tags live (run as root).
#
#   sh log-tag-mutes/apply.sh
#
# The props are persistent, so they are live immediately and stay across reboots.
# The module only re-asserts them at every boot, before the power HAL starts.
set -e

DIR=$(cd "$(dirname "$0")" && pwd)
MOD=/data/adb/modules/log_tag_mutes

RESETPROP=/data/adb/ksu/bin/resetprop
[ -x "$RESETPROP" ] || RESETPROP=setprop

echo "[*] installing module files into $MOD"
mkdir -p "$MOD"
cp -f "$DIR/module.prop" "$MOD/module.prop"
cp -f "$DIR/post-fs-data.sh" "$MOD/post-fs-data.sh"
chmod 644 "$MOD/module.prop"
chmod 755 "$MOD/post-fs-data.sh"
ls -l "$MOD"

echo "[*] persist log tags at level E (silence)"
$RESETPROP persist.log.tag.ImsProvisioningController E
$RESETPROP persist.log.tag.libPowerHal E
$RESETPROP persist.log.tag.libPowerHal-bt E
$RESETPROP persist.log.tag.mtkpower_client E
echo "     ImsProvisioningController=$(getprop persist.log.tag.ImsProvisioningController)"
echo "     libPowerHal=$(getprop persist.log.tag.libPowerHal)"
echo "     libPowerHal-bt=$(getprop persist.log.tag.libPowerHal-bt)"
echo "     mtkpower_client=$(getprop persist.log.tag.mtkpower_client)"

echo "[+] done. nothing to reboot for the tags themselves; the boot-time"
echo "    re-assert starts with the next boot."
