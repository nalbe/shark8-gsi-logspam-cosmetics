#!/system/bin/sh
# log-tag-mutes: restore the stock log levels and remove the module (run as root).
#
# The stock value of a persist.log.tag.* prop is empty (= the default level of
# the tag's C code), so the tags are reset to "" and not to "I". The old module
# reset them to I, which leaves libPowerHal at INFO even after the revert.
set -e

MOD=/data/adb/modules/log_tag_mutes

RESETPROP=/data/adb/ksu/bin/resetprop
[ -x "$RESETPROP" ] || RESETPROP=setprop

if [ -d "$MOD" ]; then
    rm -rf "$MOD"
    echo "[*] module $MOD removed"
else
    echo "[*] module not present, nothing to remove"
fi

$RESETPROP persist.log.tag.ImsProvisioningController ""
$RESETPROP persist.log.tag.libPowerHal ""
$RESETPROP persist.log.tag.libPowerHal-bt ""
$RESETPROP persist.log.tag.mtkpower_client ""
echo "[*] log tags reset: ImsProvisioningController='$(getprop persist.log.tag.ImsProvisioningController)' libPowerHal=$(getprop persist.log.tag.libPowerHal) libPowerHal-bt=$(getprop persist.log.tag.libPowerHal-bt) mtkpower_client=$(getprop persist.log.tag.mtkpower_client)"

echo "[+] done. no reboot needed for the tags, the module removal needs one"
