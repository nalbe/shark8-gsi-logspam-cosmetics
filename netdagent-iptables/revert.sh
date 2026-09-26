#!/system/bin/sh
# netdagent-iptables: remove the overlay module (run as root).
# Nothing was written to /vendor, so after the reboot the stock daemon is back.
set -e

MOD=/data/adb/modules/netdagent_iptables

if [ -d "$MOD" ]; then
    rm -rf "$MOD"
    echo "[*] module $MOD removed"
else
    echo "[*] module not present, nothing to remove"
fi

echo "[+] done. REBOOT to unmount the overlay: adb reboot"
