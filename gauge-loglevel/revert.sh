#!/system/bin/sh
# gauge-loglevel: remove the module (run as root).
#
#   sh gauge-loglevel/revert.sh
#
# Nothing is written back: FG_daemon_log_level is a driver module parameter, so
# it returns to the driver default on the next reboot by itself, and the stock
# value was never recorded (the old combined shark8_quietlogs module had already
# set it to 0 before this module existed). A reboot is the only thing that
# clears it.
set -e

MOD=/data/adb/modules/gauge_loglevel
GAUGE=/sys/devices/platform/soc/10026000.pwrap/10026000.pwrap:mt6366/mt6358-gauge/FG_daemon_log_level

if [ -d "$MOD" ]; then
    rm -rf "$MOD"
    echo "[*] module $MOD removed"
else
    echo "[*] module not present, nothing to remove"
fi

if [ -r "$GAUGE" ]; then
    echo "[*] FG_daemon_log_level is still $(cat "$GAUGE") until the next reboot"
    echo "    (driver default returns by itself, nothing to write back)"
else
    echo "[*] gauge node not present"
fi

echo "[+] done. the boot-time write is gone with the module; reboot to get the"
echo "    driver default back."
