#!/system/bin/sh
# alarmtimer-freezer: install the module on the device and apply the fix live.
# Run as root (adb root or su):
#
#   sh alarmtimer-freezer/apply.sh
#
# Live apply sets the DeviceConfig flag and thaws whatever is already frozen, but
# CachedAppOptimizer reads the flag once at system_server start, so the freeze
# stays off only after ONE REBOOT. The install therefore ends with a reboot hint.
set -e

DIR=$(cd "$(dirname "$0")" && pwd)
MODDIR=/data/adb/modules
MOD=$MODDIR/alarmtimer_freezer_off
NAMESPACE=activity_manager_native_boot
KEY=use_freezer
CFG=/system/bin/device_config

FILES="service.sh thaw.sh measure.sh whoblocks.sh findfrozen.sh"

echo "[*] installing module files into $MOD"
mkdir -p "$MOD"
cp -f "$DIR/module.prop" "$MOD/module.prop"
for f in $FILES; do
    cp -f "$DIR/$f" "$MOD/$f"
done
chmod 644 "$MOD/module.prop"
for f in $FILES; do
    chmod 755 "$MOD/$f"
done
ls -l "$MOD"

echo "[*] setting $NAMESPACE/$KEY=false"
"$CFG" put "$NAMESPACE" "$KEY" false
echo "     now: $("$CFG" get "$NAMESPACE" "$KEY")  (was: true on a stock GSI)"

echo "[*] thawing cgroups frozen before the flag change"
sh "$MOD/thaw.sh" thaw
sh "$MOD/thaw.sh" thaw
echo "     frozen left: $(sh "$MOD/thaw.sh" count)"

echo "[*] live state"
echo "     wakefulness: $(dumpsys power | grep mWakefulness= | tr -d ' ')"
echo "     alarmtimer:  $(cat /sys/kernel/debug/wakeup_sources 2>/dev/null | grep alarmtimer.1.auto | cut -f2,4)"

cat <<'EOF'

[+] module installed.

    REBOOT NOW (adb reboot) - required. The flag is stored in the DeviceConfig DB
    and read by CachedAppOptimizer when system_server starts; the put above is
    applied for the *next* boot, which is also the boot where the freezer stays
    off for good. Without the reboot the freezer keeps working and cgroups will
    slowly freeze again.

    After the reboot, verify with (as root):
        adb shell sh /data/adb/modules/alarmtimer_freezer_off/measure.sh 180
        adb shell sh /data/adb/modules/alarmtimer_freezer_off/whoblocks.sh 150
    A healthy run: alarmtimer counter flat, 0 aborts/min for long stretches,
    frozen count 0, and no "failed to suspend: error -16" in the buffer.
EOF

exit 0
