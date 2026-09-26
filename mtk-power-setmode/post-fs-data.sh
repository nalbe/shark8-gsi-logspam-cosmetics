#!/system/bin/sh
# mtk_power_setmode: relabel the overlay payload to vendor_file on every boot.
#
# `ksud module install` extracts zip payloads as u:object_r:system_file:s0, and
# KernelSU 0.9.4 mounts the /vendor overlay with seclabel, so the linker sees the
# replacement library with that label instead of the stock vendor_file. Vendor
# HAL domains are only granted vendor_file, so mtk_hal_power is denied on the
# very library it has to load:
#
#   F/linker: CANNOT LINK EXECUTABLE "/vendor/bin/hw/vendor.mediatek.hardware.mtkpower@1.0-service":
#             library "android.hardware.power-service-mediatek.so" not found
#   avc:  denied  { read } for  name="android.hardware.power-service-mediatek.so"
#         dev="overlay" scontext=u:r:mtk_hal_power:s0
#         tcontext=u:object_r:system_file:s0 tclass=file permissive=0
#
# That one is fatal: init restarts the HAL every 5 s, android.hardware.power.
# IPower/default never registers and the device never finishes booting.
#
# apply.sh already chcon'd the payload for manual installs, so only zip
# installs were broken. This makes every boot self-heal. /vendor is never
# written, only the xattr of the file inside the module directory.
MODDIR=${0%/*}
VENDOR="$MODDIR/vendor"

[ -d "$VENDOR" ] || exit 0

chcon -R u:object_r:vendor_file:s0 "$VENDOR" 2>/dev/null

exit 0
