#!/system/bin/sh
# alarmtimer-freezer (KernelSU service.sh): keep the app-freezer off, clear frozen cgroups.
#
# WHY
#   With the app-freezer enabled, a frozen task cannot consume or re-arm its POSIX
#   alarm-clock timer, so the expiry stays in the RTC alarmtimer's timerqueue with
#   an "expires" the task will never reach. alarmtimer_suspend() refuses to let the
#   device sleep while the next alarm is less than 2 s away:
#
#       if (ktime_to_ns(min) < 2 * NSEC_PER_SEC) {
#               pm_wakeup_event(dev, 2 * MSEC_PER_SEC);
#               return -EBUSY;
#       }
#
#   Every s2idle attempt is then aborted, forever, and the device never sleeps:
#
#       E alarmtimer.1.auto: PM: failed to suspend: error -16
#       I Abort: Device alarmtimer.1.auto failed to suspend: error -16
#       I [C700000] [name: spm&] Pending Wakeup Sources: alarmtimer.1.auto
#
#   Measured on this device (screen off, Dozing): 12-15 aborts/min, 100% of suspend
#   attempts failing, deep-sleep drain. After the fix: ~1.3 aborts/min (only at wake
#   boundaries), 0% battery drop over 10 min with the screen off.
#
# THE FIX
#   device_config put activity_manager_native_boot use_freezer false
#
#   The value lives in the DeviceConfig DB and therefore persists across reboots by
#   itself; re-asserting it here only protects against an OTA/ROM that resets the DB.
#
#   IMPORTANT: CachedAppOptimizer reads the flag exactly once, in its constructor,
#   and the DeviceConfig service is hosted by system_server. Any `put` from this
#   script therefore lands AFTER that read, so it only takes effect on the NEXT
#   boot. A live install needs one reboot; the thaw below only clears the damage
#   done during the current boot.
#
# COST
#   Cached background apps are no longer frozen: they keep running and cost a little
#   more idle wakeups with the screen on. Deep sleep - worth far more on this device -
#   works again. Reverting is one flag (see revert.sh).
#
# Not used on purpose:
#   * unbinding /sys/bus/platform/devices/alarmtimer.1.auto - that device programs the
#     RTC for wakeups, so RTC-based alarms (alarm clock, AlarmManager wakeups) would
#     stop working after suspend;
#   * touching /proc/timer_list - read-only, and the hrtimer address it prints cannot
#     be mapped back to the owning process from userspace.
#
# Run context: root, u:r:su:s0 (KernelSU). Writing /sys/fs/cgroup/*/cgroup.freeze is
# allowed there; /sys/fs/cgroup itself has no cgroup.freeze on this build.

MODDIR=${0%/*}
NAMESPACE=activity_manager_native_boot
KEY=use_freezer
CFG=/system/bin/device_config
CGROUP_ROOT=/sys/fs/cgroup

log() { /system/bin/log -t alarmtimer-freezer "$@" 2>/dev/null; }

count_frozen() {
    find "$CGROUP_ROOT" -maxdepth 3 -name cgroup.events -exec cat {} \; 2>/dev/null |
        grep -c 'frozen 1'
}

thaw_all() {
    _n=0
    for f in $(find "$CGROUP_ROOT" -maxdepth 3 -name cgroup.freeze 2>/dev/null); do
        if echo 0 > "$f" 2>/dev/null; then
            _n=$((_n + 1))
        fi
    done
    echo "$_n"
}

# 1. Wait for system_server to host DeviceConfig (bounded, ~120 s total budget).
_i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$_i" -lt 60 ]; do
    sleep 2
    _i=$((_i + 2))
done

# 2. Assert the flag. Idempotent, cheap, and self-healing after a ROM/OTA reset.
_val=""
if [ -x "$CFG" ]; then
    "$CFG" put "$NAMESPACE" "$KEY" false >/dev/null 2>&1
    _val=$("$CFG" get "$NAMESPACE" "$KEY" 2>/dev/null)
fi
if [ "$_val" != "false" ]; then
    # one retry: the binder service may have just come up
    sleep 5
    [ -x "$CFG" ] && "$CFG" put "$NAMESPACE" "$KEY" false >/dev/null 2>&1
    _val=$("$CFG" get "$NAMESPACE" "$KEY" 2>/dev/null)
fi

# 3. Clear whatever the freezer already froze this boot. Two passes: the daemon
#    re-freezes on its own cadence, and one pass can race it.
_t1=$(thaw_all)
sleep 20
_t2=$(thaw_all)
_left=$(count_frozen)

# 4. One summary line, nothing per-iteration (this is a logspam project).
log "use_freezer=$_val thawed=${_t1}+${_t2} frozen_left=$_left (effective for the next boot)"
if [ "$_val" != "false" ]; then
    log "WARNING: could not set $NAMESPACE/$KEY, the suspend-abort storm will continue"
fi

exit 0
