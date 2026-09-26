#!/system/bin/sh
# charger-loglevel: install the module and set the charger log level live (run as root).
#
#   sh charger-loglevel/apply.sh
#
# The node is a driver module parameter, so the value is runtime-only and comes
# back at every reboot; post-fs-data.sh re-asserts it. A live apply means you do
# not have to reboot to see it now.
set -e

DIR=$(cd "$(dirname "$0")" && pwd)
MOD=/data/adb/modules/charger_loglevel
CHARGER=/sys/devices/platform/charger/charger_log_level

echo "[*] installing module files into $MOD"
mkdir -p "$MOD"
cp -f "$DIR/module.prop" "$MOD/module.prop"
cp -f "$DIR/post-fs-data.sh" "$MOD/post-fs-data.sh"
chmod 644 "$MOD/module.prop"
chmod 755 "$MOD/post-fs-data.sh"
ls -l "$MOD"

if [ -w "$CHARGER" ]; then
    echo "[*] writing 0 to $CHARGER"
    echo 0 > "$CHARGER"
    echo "     now: $(cat "$CHARGER")"
else
    echo "[!] $CHARGER not writable - charger platform device not up yet?"
    echo "    reboot and let post-fs-data.sh do it at boot."
fi

if [ -d /data/adb/modules/shark8_quietlogs ]; then
    cat <<'EOF'

[!] the old combined module is still installed and writes the same node:
      /data/adb/modules/shark8_quietlogs
    Remove it, or two modules will own the same knob:
        adb shell su -c 'rm -rf /data/adb/modules/shark8_quietlogs'
EOF
fi

cat <<'EOF'

[+] done. runtime value, no reboot needed to see it; the boot-time re-assert
    starts with the next boot.

    Heads up: this will not silence sgm4154x_dump_register, see README.md.
EOF

exit 0
