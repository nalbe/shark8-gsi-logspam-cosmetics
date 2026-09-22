#!/system/bin/sh
# Persistently apply classic-format sepolicy rules via ksud, because
# KernelSU 0.9.4 cannot parse magisk colon-format sepolicy.rule and its
# boot-time load path is unreliable. Rules live in sepolicy.rule.
MODDIR=${0%/*}
RULES="$MODDIR/sepolicy.rule"

if [ -f "$RULES" ]; then
    # KernelSU sepolicy binary
    KSUD=/data/adb/ksud
    if [ -x "$KSUD" ]; then
        # Apply rules (classic space-separated format, logged one line per rule).
        "$KSUD" sepolicy apply "$RULES" >/dev/null 2>&1

        # 0.9.4 has no reset_avc_cache; stale deny cache keeps old denials firing
        # even after rules land. Toggle enforcing to flush AVC cache.
        if [ -w /sys/fs/selinux/enforce ]; then
            echo 0 > /sys/fs/selinux/enforce 2>/dev/null
            echo 1 > /sys/fs/selinux/enforce 2>/dev/null
        fi
    fi
fi

# MTK power-stack log tags at E (errors only). Silences, per game load:
#   libPowerHal     ~418 lines  ([perfLockAcq] idx/hdl/hint/pid/lock_user,
#                                [PE] eara_io_service update cmd, [setGPUFreq])
#   mtkpower_client ~224 lines  (perf_lock_acq hdl/dur/num/tid, ret_hdl,
#                                DEBUG [perf_lock_acq] list:0x.. dump)
# Both come from /vendor/bin/eara_io_service renewing a 500 ms QoS lock every
# ~100 ms during tagged IO. Tags with '@' (eara_io@boost, eara_io@eval) are
# handled by the lib_eara_io_scndet.so binary patch (section 8), not here.
# (The old claim that '@' is illegal in a property name was wrong: the stock
# image ships persist.log.tag.mtkpower@impl=I and setting it to V works.)
#
# libPowerHal-bt is the second tag libpowerhal logs under (the "libPowerHal-bt"
# literal at .rodata 0xD48C is used as the log tag). Only the BT low-latency
# path uses it: perfScnEnable of PERF_RES_NET_BT_AUDIO_LOW_LATENCY logs 3 INFO
# lines per notify ("bt a2dp low latency enter = 1, data:0x..", "open provider
# cb", "get provider successfully") plus errors. A hyphen in the property name
# is fine - setprop accepts it and the HAL picks it up.
RESETPROP=/data/adb/ksu/bin/resetprop
[ -x "$RESETPROP" ] || RESETPROP=setprop

$RESETPROP persist.log.tag.libPowerHal E
$RESETPROP persist.log.tag.libPowerHal-bt E
$RESETPROP persist.log.tag.mtkpower_client E

exit 0
