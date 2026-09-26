#!/system/bin/sh
# eara-io-scene-detector: remove the overlay module (run as root).
# Nothing was written to /vendor, so after the reboot the stock library is back.
set -e

MOD=/data/adb/modules/eara_io_scene_detector

if [ -d "$MOD" ]; then
    rm -rf "$MOD"
    echo "[*] module $MOD removed"
else
    echo "[*] module not present, nothing to remove"
fi

echo "[+] done. REBOOT to unmount the overlay: adb reboot"
