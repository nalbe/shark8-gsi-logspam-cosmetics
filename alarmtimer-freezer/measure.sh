#!/system/bin/sh
# measure.sh [seconds] [step] - quantify the alarmtimer suspend-abort storm.
#
# Primary metric is the alarmtimer wakeup counter from
# /sys/kernel/debug/wakeup_sources: it only increments on a real -EBUSY abort
# (alarmtimer_suspend calls pm_wakeup_event on that path), so it is exact and
# immune to logcat buffer rotation. The logcat counts are context only.
#
# Usage on device (as root, u:r:su:s0):
#   sh measure.sh 180          # 3 min, 10 s samples
#   sh measure.sh 60 5         # 1 min, 5 s samples
#
# A healthy (fixed) run: the counter is flat for long stretches and the phone
# stops logging "suspend entry" entirely while it sleeps. A broken run: the
# counter climbs on every sample and the abort rate matches the number of
# suspend attempts.
#
# Side effects: clears the main logcat buffer, and mounts debugfs if it is not
# mounted yet (Android does not mount it by default on this build).

DUR=${1:-120}
STEP=${2:-10}
DEBUG=/sys/kernel/debug/wakeup_sources

[ -r "$DEBUG" ] || mount -t debugfs none /sys/kernel/debug 2>/dev/null

counter() { awk '/^alarmtimer\.1\.auto/ { print $4 }' "$DEBUG" 2>/dev/null; }

logcount() { logcat -d 2>/dev/null | grep -c "$1"; }

frozen_count() {
    find /sys/fs/cgroup -maxdepth 3 -name cgroup.events -exec cat {} \; 2>/dev/null |
        grep -c 'frozen 1'
}

logcat -c
first=$(counter)
prev=$first
start_sec=$(( $(date +%s) ))
echo "wakefulness: $(dumpsys power 2>/dev/null | grep mWakefulness= | tr -d ' ')"
[ -n "$first" ] || echo "WARNING: $DEBUG unreadable, aborts will be logcat-only"

i=$STEP
while [ "$i" -le "$DUR" ]; do
    sleep "$STEP"
    now=$(counter)
    delta="-"
    [ -n "$now" ] && [ -n "$prev" ] && delta=$((now - prev))
    prev="$now"
    echo "t=${i}s aborts+$delta counter=${now:-?} entry=$(logcount 'suspend entry') ebusy=$(logcount 'failed to suspend: error') early_wake=$(logcount 'Some devices failed to suspend') frozen=$(frozen_count)"
    i=$((i + STEP))
done

end_sec=$(( $(date +%s) ))
elapsed=$((end_sec - start_sec))
[ "$elapsed" -lt 1 ] && elapsed=1
final=$(counter)
if [ -n "$final" ] && [ -n "$first" ]; then
    total=$((final - first))
    echo "---- window ${elapsed}s: $total aborts ($(( total * 60 / elapsed )) aborts/min)"
else
    echo "---- window ${elapsed}s: counter unavailable, use the ebusy column"
fi
echo "---- last sleep: $(dumpsys power 2>/dev/null | grep mLastSleepTime)"
