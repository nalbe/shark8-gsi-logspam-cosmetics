#!/system/bin/sh
# eara-io-scene-detector: install the overlay module (run as root, adb root or su).
#
#   sh eara-io-scene-detector/apply.sh
#
# /vendor is never written. The patched library is a KernelSU overlay, so it is
# live only after `adb reboot` (adding an overlay file to a module directory
# does not show up before the next boot).
#
# The probe under tools/ is a host+device verification tool, not a module file:
# it is pushed by hand when the eara_io lines have to be reproduced on demand.
set -e

DIR=$(cd "$(dirname "$0")" && pwd)
MOD=/data/adb/modules/eara_io_scene_detector
SO=lib_eara_io_scndet.so

echo "[*] installing module files into $MOD"
mkdir -p "$MOD/vendor/lib64"
cp -f "$DIR/module.prop" "$MOD/module.prop"
cp -f "$DIR/vendor/lib64/$SO" "$MOD/vendor/lib64/$SO"
chmod 644 "$MOD/module.prop" "$MOD/vendor/lib64/$SO"
chcon -R u:object_r:vendor_file:s0 "$MOD/vendor" 2>/dev/null || true

echo "[*] payload md5"
echo "    $(md5sum "$MOD/vendor/lib64/$SO" | cut -d' ' -f1)  $SO"
echo "    want 71af817be84f670a088ce439db96e18c  (stock 54218e4a8c26e09645c5d35f622ad4fd)"

echo "[+] done. REBOOT to mount the vendor overlay: adb reboot"
