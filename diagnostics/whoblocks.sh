#!/system/bin/sh
# whoblocks.sh [seconds] - who is aborting s2idle, and what wakes the device.
#
# Answers the question the alarmtimer counter cannot: is the remaining abort
# traffic still the alarmtimer, or is it some other device / early wakeup?
#
# Usage on device (as root):
#   sh whoblocks.sh 150
#
# Reading the output:
#   "Device X failed to suspend: error -N"  - a real dpm callback failure, one
#       line per abort, named by device. On this device only
#       alarmtimer.1.auto with -16 (EBUSY) shows up.
#   "Some devices failed to suspend, or early wake event detected" - the resume
#       path's summary. It appears even when nothing failed: a device that
#       requested a wakeup during the suspend (early wake) produces the same
#       line, so its count can exceed the "Device ... failed" count.
#   "Pending Wakeup Sources" / "Last active Wakeup Source" - the MTK suspend
#       driver's resume-time list of what was (last) awake. Informational, not an
#       error: on this device the recurring entries are "WLAN timeout" (vendor
#       WLAN keepalive, wakes the device roughly every 6 s) and "[timerfd]".
#
# Side effect: clears the main logcat buffer. Counts come from a rotating buffer,
# so keep the window short enough (a few minutes) that the kernel lines survive.

DUR=${1:-120}
DEBUG=/sys/kernel/debug/wakeup_sources

[ -r "$DEBUG" ] || mount -t debugfs none /sys/kernel/debug 2>/dev/null

logcat -c
sleep "$DUR"
D=$(logcat -d 2>/dev/null)

echo "=== suspend entries:            $(echo "$D" | grep -c 'suspend entry')"
echo "=== Some devices failed:        $(echo "$D" | grep -c 'Some devices failed')"
echo "=== dpm callback failures:      $(echo "$D" | grep -c 'failed to suspend: error')"
echo "=== alarmtimer aborts (-EBUSY): $(echo "$D" | grep -c 'alarmtimer.1.auto: PM: failed to suspend')"
echo
echo "=== aborting devices:"
echo "$D" | grep -o 'Device [a-zA-Z0-9._-]* failed to suspend: error [-0-9]*' | sort | uniq -c | sort -rn
echo
echo "=== pending wakeup sources:"
echo "$D" | grep -o 'Pending Wakeup Sources: .*' | sort | uniq -c | sort -rn | head -n 8
echo
echo "=== last active wakeup source:"
echo "$D" | grep -o 'Last active Wakeup Source: .*' | sort | uniq -c | sort -rn | head -n 8
echo
echo "=== alarmtimer counter (active wakeup / wakeup count):"
awk '/^alarmtimer\.1\.auto/ { print "   " $2 " / " $4 }' "$DEBUG" 2>/dev/null
echo
echo "=== top wakeup sources by active_count:"
sort -k 2 -n -r "$DEBUG" 2>/dev/null | head -n 8
