#!/system/bin/sh
# selinux-avc-rules: install the module on the device and apply the rules live.
# Run as root (adb root or su):
#
#   sh selinux-avc-rules/apply.sh
#
# The rules are live immediately. The post-fs-data.sh re-apply is what keeps
# them after a reboot; removing the module does NOT un-apply rules that are
# already in the kernel policy, that needs a reboot (see revert.sh).
set -e

DIR=$(cd "$(dirname "$0")" && pwd)
MOD=/data/adb/modules/selinux_avc_rules

echo "[*] installing module files into $MOD"
mkdir -p "$MOD"
cp -f "$DIR/module.prop" "$MOD/module.prop"
cp -f "$DIR/sepolicy.rule" "$MOD/sepolicy.rule"
cp -f "$DIR/post-fs-data.sh" "$MOD/post-fs-data.sh"
chmod 644 "$MOD/module.prop" "$MOD/sepolicy.rule"
chmod 755 "$MOD/post-fs-data.sh"
ls -l "$MOD"

echo "[*] apply sepolicy rules immediately (classic format)"
if [ -x /data/adb/ksud ]; then
    /data/adb/ksud sepolicy apply "$MOD/sepolicy.rule"
    # 0.9.4 lacks reset_avc_cache; flush stale deny cache via enforcing toggle
    if [ -w /sys/fs/selinux/enforce ]; then
        echo 0 > /sys/fs/selinux/enforce 2>/dev/null
        echo 1 > /sys/fs/selinux/enforce 2>/dev/null
    fi
    echo "[*] rules live: $(grep -c '^allow' "$MOD/sepolicy.rule") allow lines"
else
    echo "[!] /data/adb/ksud not found - is this a KernelSU device?"
fi

echo "[+] done. reboot to let post-fs-data.sh own the boot: adb reboot"
