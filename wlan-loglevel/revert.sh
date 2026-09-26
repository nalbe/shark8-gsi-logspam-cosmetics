#!/system/bin/sh
# wlan-loglevel: restore the stock driver log level and remove the module (run as root).
#
#   sh wlan-loglevel/revert.sh
#
# The stock mask is 0x2f on every one of the 32 modules (ERROR|WARN|STATE|EVENT|
# INFO) and the stock autoPerfCfg is ForceEnable:1 (always enable the performance
# monitor), so that is what gets written back. Expect the [wlan] firehose back.
set -e

MOD=/data/adb/modules/wlan_loglevel
DBG=/proc/net/wlan/dbgLevel
AUTO=/proc/net/wlan/autoPerfCfg
STOCK=0x2f
IDX="0x00 0x01 0x02 0x03 0x04 0x05 0x06 0x07 0x08 0x09 0x0a 0x0b 0x0c 0x0d \
0x0e 0x0f 0x10 0x11 0x12 0x13 0x14 0x15 0x16 0x17 0x18 0x19 0x1a 0x1b \
0x1c 0x1d 0x1e 0x1f"

if [ -d "$MOD" ]; then
    rm -rf "$MOD"
    echo "[*] module $MOD removed"
else
    echo "[*] module not present, nothing to remove"
fi

if [ -w "$DBG" ]; then
    echo "[*] restoring stock level $STOCK on all 32 modules"
    for i in $IDX; do
        echo "$i:$STOCK" > "$DBG" 2>/dev/null
    done
    if [ -w "$AUTO" ]; then
        echo ForceEnable:1 > "$AUTO" 2>/dev/null
    fi
    echo "     modules at $STOCK now: $(grep -c "$STOCK" "$DBG" 2>/dev/null || echo '?')  (want 32)"
else
    echo "[*] $DBG not present, nothing to restore live (a reboot resets it anyway)"
fi

echo "[+] done. the boot-time re-assert is gone with the module; no reboot"
echo "    needed, the mask is a runtime value and the next boot starts at stock."
