#!/system/bin/sh
# shark8-gsi-logspam-cosmetics: apply on the device (run as root, adb root or su).
# Installs the KernelSU module, persists the log-level props, applies the rules.
set -e

DIR=$(cd "$(dirname "$0")" && pwd)
MODDIR=/data/adb/modules
MOD=$MODDIR/selinux_cosmetics
LIBS="android.hardware.power-service-mediatek.so libpowerhal.so lib_eara_io_scndet.so"
BINS="netdagent"

RESETPROP=/data/adb/ksu/bin/resetprop
[ -x "$RESETPROP" ] || RESETPROP=setprop

echo "[*] installing module files"
mkdir -p "$MOD/vendor/lib64" "$MOD/vendor/bin"
cp -f "$DIR/../module/module.prop"      "$MOD/module.prop"
cp -f "$DIR/../module/sepolicy.rule"    "$MOD/sepolicy.rule"
cp -f "$DIR/../module/post-fs-data.sh"  "$MOD/post-fs-data.sh"
for L in $LIBS; do
    cp -f "$DIR/../module/vendor/lib64/$L" "$MOD/vendor/lib64/$L"
    chmod 644 "$MOD/vendor/lib64/$L"
done
for B in $BINS; do
    cp -f "$DIR/../module/vendor/bin/$B" "$MOD/vendor/bin/$B"
    chmod 755 "$MOD/vendor/bin/$B"
done
chmod 644 "$MOD/module.prop" "$MOD/sepolicy.rule"
chmod 755 "$MOD/post-fs-data.sh"
chcon -R u:object_r:vendor_file:s0 "$MOD/vendor" 2>/dev/null || true
# the daemon keeps its own type: the init service is entered via netdagent_exec
chcon u:object_r:netdagent_exec:s0 "$MOD/vendor/bin/netdagent" 2>/dev/null || true

echo "[*] patched vendor libraries"
for L in $LIBS; do
    echo "    $(md5sum "$MOD/vendor/lib64/$L" | cut -d' ' -f1)  $L"
done
echo "    want a52fb102917c13c0b15ed83a13598394  android.hardware.power-service-mediatek.so (stock 40aea46435089ab1e2fc002d67f8ec2d)"
echo "    want 58bd610b542ba4ca0747718d1189312a  libpowerhal.so (stock eb618de9c44807d6ec1b21eb47ee5eb0)"
echo "    want 71af817be84f670a088ce439db96e18c  lib_eara_io_scndet.so (stock 54218e4a8c26e09645c5d35f622ad4fd)"

echo "[*] patched vendor binaries"
for B in $BINS; do
    echo "    $(md5sum "$MOD/vendor/bin/$B" | cut -d' ' -f1)  $B"
done
echo "    want f58dbc8877c401ed4d2bcf9d0436bb42  netdagent (stock 6e3f6b430386eb032715038bf7544120)"

echo "[*] persist log tags at level E (silence)"
$RESETPROP persist.log.tag.ImsProvisioningController E
$RESETPROP persist.log.tag.libPowerHal E
$RESETPROP persist.log.tag.libPowerHal-bt E
$RESETPROP persist.log.tag.mtkpower_client E
echo "     ImsProvisioningController=$(getprop persist.log.tag.ImsProvisioningController)"
echo "     libPowerHal=$(getprop persist.log.tag.libPowerHal)"
echo "     libPowerHal-bt=$(getprop persist.log.tag.libPowerHal-bt)"
echo "     mtkpower_client=$(getprop persist.log.tag.mtkpower_client)"

echo "[*] apply sepolicy rules immediately (classic format)"
if [ -x /data/adb/ksud ]; then
    /data/adb/ksud sepolicy apply "$MOD/sepolicy.rule"
    # 0.9.4 lacks reset_avc_cache; flush stale deny cache via enabling toggle
    if [ -w /sys/fs/selinux/enforce ]; then
        echo 0 > /sys/fs/selinux/enforce 2>/dev/null
        echo 1 > /sys/fs/selinux/enforce 2>/dev/null
    fi
fi

echo "[+] done. reboot to mount the vendor overlay: adb reboot"
