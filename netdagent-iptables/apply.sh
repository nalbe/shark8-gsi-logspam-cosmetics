#!/system/bin/sh
# netdagent-iptables: install the overlay module (run as root, adb root or su).
#
#   sh netdagent-iptables/apply.sh
#
# /vendor is never written. The patched daemon is a KernelSU overlay, so it is
# live only after `adb reboot` (adding an overlay file to a module directory
# does not show up before the next boot).
#
# SELinux: the init service enters the daemon through
# u:object_r:netdagent_exec:s0 (/(vendor|system/vendor)/bin/netdagent in
# vendor_file_contexts), so the overlay has to carry that exact type - a plain
# vendor_file label would make init refuse to execute it.
set -e

DIR=$(cd "$(dirname "$0")" && pwd)
MOD=/data/adb/modules/netdagent_iptables
BIN=netdagent

echo "[*] installing module files into $MOD"
mkdir -p "$MOD/vendor/bin"
cp -f "$DIR/module.prop" "$MOD/module.prop"
cp -f "$DIR/vendor/bin/$BIN" "$MOD/vendor/bin/$BIN"
chmod 644 "$MOD/module.prop"
chmod 755 "$MOD/vendor/bin/$BIN"
chcon -R u:object_r:vendor_file:s0 "$MOD/vendor" 2>/dev/null || true
chcon u:object_r:netdagent_exec:s0 "$MOD/vendor/bin/$BIN" 2>/dev/null || true
ls -lZ "$MOD/vendor/bin/$BIN" 2>/dev/null || ls -l "$MOD/vendor/bin/$BIN"

echo "[*] payload md5"
echo "    $(md5sum "$MOD/vendor/bin/$BIN" | cut -d' ' -f1)  $BIN"
echo "    want f58dbc8877c401ed4d2bcf9d0436bb42  (stock 6e3f6b430386eb032715038bf7544120)"

echo "[+] done. REBOOT to mount the vendor overlay: adb reboot"
