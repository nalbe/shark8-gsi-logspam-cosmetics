#!/system/bin/sh
# selinux-avc-rules: remove the module (run as root).
#
# Removing the module only stops the boot-time re-apply. Rules that are already
# in the kernel policy cannot be un-applied from userspace, so the denials stay
# gone until the next reboot - which is what we want here anyway, because the
# rules are health checks the GSI/vendor mix lost, not masks.
set -e

MOD=/data/adb/modules/selinux_avc_rules

if [ -d "$MOD" ]; then
    rm -rf "$MOD"
    echo "[*] module $MOD removed"
else
    echo "[*] module not present, nothing to remove"
fi

echo "[+] done. the applied rules stay in the policy until the reboot: adb reboot"
