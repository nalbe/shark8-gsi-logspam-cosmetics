#!/system/bin/sh
# selinux_avc_rules: re-apply the sepolicy rules at every boot, because
# KernelSU 0.9.4 cannot parse the magisk colon format of sepolicy.rule and its
# own boot-time load path is unreliable. The rules are applied twice on purpose:
# once by KernelSU itself, once here through ksud, which logs the result.
MODDIR=${0%/*}
RULES="$MODDIR/sepolicy.rule"

if [ -f "$RULES" ]; then
    # KernelSU sepolicy binary
    KSUD=/data/adb/ksud
    if [ -x "$KSUD" ]; then
        # Apply rules (classic space-separated format, logged one line per rule).
        "$KSUD" sepolicy apply "$RULES" >/dev/null 2>&1

        # 0.9.4 has no reset_avc_cache; a stale deny cache keeps old denials
        # firing even after the rules land. Toggle enforcing to flush it.
        if [ -w /sys/fs/selinux/enforce ]; then
            echo 0 > /sys/fs/selinux/enforce 2>/dev/null
            echo 1 > /sys/fs/selinux/enforce 2>/dev/null
        fi
    fi
fi

exit 0
