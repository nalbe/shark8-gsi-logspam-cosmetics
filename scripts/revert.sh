#!/system/bin/sh
# shark8-gsi-logspam-cosmetics: full revert (run as root).
# Nothing was written to /vendor - dropping the overlay restores the stock
# library. The log-tag properties are persistent, so they are reset explicitly.
set -e

MODDIR=/data/adb/modules
MOD=$MODDIR/selinux_cosmetics

RESETPROP=/data/adb/ksu/bin/resetprop
[ -x "$RESETPROP" ] || RESETPROP=setprop

if [ -d "$MOD" ]; then
  rm -rf "$MOD"
  echo "[*] module $MOD removed"
else
  echo "[*] module not present, nothing to remove"
fi

$RESETPROP persist.log.tag.ImsProvisioningController ""
$RESETPROP persist.log.tag.libPowerHal I
$RESETPROP persist.log.tag.libPowerHal-bt I
$RESETPROP persist.log.tag.mtkpower_client I
echo "[*] log tags reset: ImsProvisioningController='$(getprop persist.log.tag.ImsProvisioningController)' libPowerHal=$(getprop persist.log.tag.libPowerHal) libPowerHal-bt=$(getprop persist.log.tag.libPowerHal-bt) mtkpower_client=$(getprop persist.log.tag.mtkpower_client)"

echo "[+] done. reboot to drop the patched policy + vendor overlay: adb reboot"
