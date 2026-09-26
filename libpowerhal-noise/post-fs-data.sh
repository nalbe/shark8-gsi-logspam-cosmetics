#!/system/bin/sh
# libpowerhal_noise: relabel the overlay payload to vendor_file on every boot.
#
# `ksud module install` extracts zip payloads as u:object_r:system_file:s0, and
# KernelSU 0.9.4 mounts the /vendor overlay with seclabel, so the linker sees the
# replacement library with that label instead of the stock vendor_file. Vendor
# domains are only granted vendor_file, so any of them that dlopen's
# libpowerhal.so can be denied on it:
#
#   avc:  denied  { read } for  name="libpowerhal.so" dev="overlay"
#         scontext=u:r:<vendor domain>:s0
#         tcontext=u:object_r:system_file:s0 tclass=file permissive=0
#
# The platform domains that load it most often happen to hold system_file
# permissions already, which is why this one usually only shows up as a silent
# difference rather than a crash. The overlay must look like the stock file
# anyway, so the label is fixed rather than papered over with policy.
#
# apply.sh already chcon'd the payload for manual installs, so only zip
# installs were broken. This makes every boot self-heal. /vendor is never
# written, only the xattr of the file inside the module directory.
MODDIR=${0%/*}
VENDOR="$MODDIR/vendor"

[ -d "$VENDOR" ] || exit 0

chcon -R u:object_r:vendor_file:s0 "$VENDOR" 2>/dev/null

exit 0
