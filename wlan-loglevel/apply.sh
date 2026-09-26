#!/system/bin/sh
# wlan-loglevel: install the module and set the driver log level live (run as root).
#
#   sh wlan-loglevel/apply.sh
#
# /proc writes do not persist: the mask is back to 0x2f after every reboot, and
# the module's service.sh re-asserts it at every boot. A live apply means you do
# not have to reboot to see the effect now.
set -e

DIR=$(cd "$(dirname "$0")" && pwd)
MOD=/data/adb/modules/wlan_loglevel

DBG=/proc/net/wlan/dbgLevel
AUTO=/proc/net/wlan/autoPerfCfg
LEVEL=0x03
IDX="0x00 0x01 0x02 0x03 0x04 0x05 0x06 0x07 0x08 0x09 0x0a 0x0b 0x0c 0x0d \
0x0e 0x0f 0x10 0x11 0x12 0x13 0x14 0x15 0x16 0x17 0x18 0x19 0x1a 0x1b \
0x1c 0x1d 0x1e 0x1f"

echo "[*] installing module files into $MOD"
mkdir -p "$MOD"
cp -f "$DIR/module.prop" "$MOD/module.prop"
cp -f "$DIR/service.sh" "$MOD/service.sh"
chmod 644 "$MOD/module.prop"
chmod 755 "$MOD/service.sh"
ls -l "$MOD"

if [ -w "$DBG" ]; then
    echo "[*] writing $LEVEL to all 32 dbgLevel modules (stock 0x2f)"
    for i in $IDX; do
        echo "$i:$LEVEL" > "$DBG" 2>/dev/null
    done
    if [ -w "$AUTO" ]; then
        echo ForceEnable:0 > "$AUTO" 2>/dev/null
        echo "[*] autoPerfCfg ForceEnable:0 (stock 1)"
    fi
else
    echo "[!] $DBG not writable - is the WLAN driver up? run again, or reboot"
    echo "    and let service.sh do it at boot."
fi

echo "[*] live state"
echo "     modules still at 0x2f: $(grep -c '0x2f' "$DBG" 2>/dev/null || echo '?')  (want 0)"
echo "     mcr: $(cat /proc/net/wlan/mcr 2>/dev/null)  (unchanged at 0x011c0031)"
echo "     log: /data/local/tmp/wlan_loglevel.log"

if [ -d /data/adb/modules/shark8_quietlogs ]; then
    cat <<'EOF'

[!] the old combined module is still installed:
      /data/adb/modules/shark8_quietlogs
    It writes the same dbgLevel node and owns the charger and gauge knobs, which
    now belong to ../charger-loglevel and ../gauge-loglevel. Remove it, or two
    modules will fight over the same node.
        adb shell su -c 'rm -rf /data/adb/modules/shark8_quietlogs'
EOF
fi

cat <<'EOF'

[+] done. no reboot needed for the log level itself, it is live now; the
    boot-time re-assert in service.sh starts with the next boot.

    verify:
        adb shell cat /proc/net/wlan/dbgLevel | grep -c 0x2f   # 0
        adb shell dmesg | grep -c kalPerMonUpdate               # 0
EOF

exit 0
