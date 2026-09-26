#!/system/bin/sh
# alarmtimer-freezer: revert the fix. Run as root (adb root or su):
#
#   sh alarmtimer-freezer/revert.sh
#
# Restores the stock app-freezer (use_freezer=true), thaws the cgroups and
# removes the module directory. CachedAppOptimizer re-reads the flag at
# system_server start, so a reboot is needed for the freezer to come back - the
# same one-boot delay as the install, in reverse.
#
# Expect the alarmtimer abort storm to return after the reboot.
set -e

DIR=$(cd "$(dirname "$0")" && pwd)
MODDIR=/data/adb/modules
MOD=$MODDIR/alarmtimer_freezer_off
NAMESPACE=activity_manager_native_boot
KEY=use_freezer
CFG=/system/bin/device_config

echo "[*] restoring $NAMESPACE/$KEY=true"
"$CFG" put "$NAMESPACE" "$KEY" true
echo "     now: $("$CFG" get "$NAMESPACE" "$KEY")"

echo "[*] thawing cgroups"
sh "$DIR/thaw.sh" thaw

echo "[*] removing $MOD"
rm -rf "$MOD"
[ -d "$MOD" ] && echo "     WARNING: $MOD still exists" || echo "     removed"

cat <<'EOF'

[+] reverted. Reboot (adb reboot) to bring the app-freezer back; the
    "E alarmtimer.1.auto: PM: failed to suspend: error -16" storm returns with
    it, 12-15 aborts/min on this device.

    The module can also be removed from the KernelSU Manager (alarmtimer_freezer_off)
    instead of using this script; remove it there and reboot.
EOF

exit 0
