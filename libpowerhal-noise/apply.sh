#!/system/bin/sh
# libpowerhal-noise: install the overlay module (run as root, adb root or su).
#
#   sh libpowerhal-noise/apply.sh
#
# /vendor is never written. The patched library is a KernelSU overlay, so it is
# live only after `adb reboot` (adding an overlay file to a module directory
# does not show up before the next boot).
set -e

DIR=$(cd "$(dirname "$0")" && pwd)
MOD=/data/adb/modules/libpowerhal_noise
SO=libpowerhal.so

echo "[*] installing module files into $MOD"
mkdir -p "$MOD/vendor/lib64"
cp -f "$DIR/module.prop" "$MOD/module.prop"
cp -f "$DIR/vendor/lib64/$SO" "$MOD/vendor/lib64/$SO"
chmod 644 "$MOD/module.prop" "$MOD/vendor/lib64/$SO"
chcon -R u:object_r:vendor_file:s0 "$MOD/vendor" 2>/dev/null || true

echo "[*] payload md5"
echo "    $(md5sum "$MOD/vendor/lib64/$SO" | cut -d' ' -f1)  $SO"
echo "    want 58bd610b542ba4ca0747718d1189312a  (stock eb618de9c44807d6ec1b21eb47ee5eb0)"

echo "[+] done. REBOOT to mount the vendor overlay: adb reboot"
