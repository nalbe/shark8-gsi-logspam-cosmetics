#!/system/bin/sh
# eara_io_scene_detector: relabel the overlay payload to vendor_file on every
# boot.
#
# `ksud module install` extracts zip payloads as u:object_r:system_file:s0, and
# KernelSU 0.9.4 mounts the /vendor overlay with seclabel, so the linker sees the
# replacement library with that label instead of the stock vendor_file. Vendor
# domains are only granted vendor_file, so eara_io_service is denied on the very
# library it has to load and crash-loops on it:
#
#   avc:  denied  { read } for  comm="eara_io_service" name="lib_eara_io_scndet.so"
#         dev="overlay" scontext=u:r:eara_io:s0
#         tcontext=u:object_r:system_file:s0 tclass=file permissive=0
#
# init restarts the service every 5 s, so the whole logspam this module exists
# to remove is replaced by a linker failure loop.
#
# apply.sh already chcon'd the payload for manual installs, so only zip
# installs were broken. This makes every boot self-heal. /vendor is never
# written, only the xattr of the file inside the module directory.
MODDIR=${0%/*}
VENDOR="$MODDIR/vendor"

[ -d "$VENDOR" ] || exit 0

chcon -R u:object_r:vendor_file:s0 "$VENDOR" 2>/dev/null

exit 0
