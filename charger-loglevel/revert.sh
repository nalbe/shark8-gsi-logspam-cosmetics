#!/system/bin/sh
# charger-loglevel: remove the module (run as root).
#
#   sh charger-loglevel/revert.sh
#
# Nothing is written back: charger_log_level is a driver module parameter, so it
# returns to the driver default on the next reboot by itself, and the stock value
# was never recorded (the old combined shark8_quietlogs module had already set it
# to 0 before this module existed). A reboot is the only thing that clears it.
set -e

MOD=/data/adb/modules/charger_loglevel
CHARGER=/sys/devices/platform/charger/charger_log_level

if [ -d "$MOD" ]; then
    rm -rf "$MOD"
    echo "[*] module $MOD removed"
else
    echo "[*] module not present, nothing to remove"
fi

if [ -r "$CHARGER" ]; then
    echo "[*] $CHARGER is still $(cat "$CHARGER") until the next reboot"
    echo "    (driver default returns by itself, nothing to write back)"
else
    echo "[*] $CHARGER not present"
fi

echo "[+] done. the boot-time write is gone with the module; reboot to get the"
echo "    driver default back."
