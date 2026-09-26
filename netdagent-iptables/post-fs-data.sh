#!/system/bin/sh
# netdagent_iptables: relabel the overlay payload on every boot.
#
# `ksud module install` extracts zip payloads as u:object_r:system_file:s0, and
# KernelSU 0.9.4 mounts the /vendor overlay with seclabel, so the patched
# netdagent is executed with that label instead of the stock one. The stock
# label is NOT vendor_file: netdagent is an init service
# (/vendor/etc/init/netdagent.rc) with its own exec type, and init domain
# transitions on it:
#
#   avc:  denied  { execute } for  path="/vendor/bin/netdagent" dev="overlay"
#         scontext=u:r:init:s0 tcontext=u:object_r:system_file:s0 tclass=file
#
# Two steps, in this order, exactly like apply.sh: the directories take
# vendor_file, then the binary takes its own netdagent_exec. Chcon'ing the tree
# to vendor_file alone is wrong - it leaves the binary without a transition
# domain and init then refuses to start the service.
#
# /vendor is never written, only the xattr of the file inside the module
# directory.
MODDIR=${0%/*}
VENDOR="$MODDIR/vendor"
BIN=netdagent

[ -d "$VENDOR" ] || exit 0

chcon -R u:object_r:vendor_file:s0 "$VENDOR" 2>/dev/null
if [ -f "$VENDOR/bin/$BIN" ]; then
    chcon u:object_r:netdagent_exec:s0 "$VENDOR/bin/$BIN" 2>/dev/null
    # init execs this file. If it lands as 0644 the service never starts:
    # "cannot execv('/vendor/bin/netdagent') ... Permission denied", status
    # 127, restart loop. build.ps1 ships it 0755, apply.sh chmods it, and this
    # is the third copy for the case where a reader ignores the zip mode.
    chmod 755 "$VENDOR/bin/$BIN" 2>/dev/null
fi

exit 0
