#!/system/bin/sh
# Name the process holding a near-expiry timer on an ALARM clock.
#
# clockid 8 = CLOCK_REALTIME_ALARM, 9 = CLOCK_BOOTTIME_ALARM. These are the only
# clocks routed through the kernel alarmtimer, i.e. the only ones that can make
# alarmtimer_suspend return -EBUSY. CLOCK_BOOTTIME (7) is uptime including
# suspend time and is what clockid 9 is measured against; CLOCK_REALTIME (0) is
# what clockid 8 is measured against.
#
# fdinfo on this kernel exposes the deadline as it_value, not expires. A disarmed
# timer reports it_value (0, 0) and is not pending, so it is not a candidate.
BB=/data/adb/ksu/bin/busybox
WINDOW=${1:-120}
STEP=${2:-5}

realtime_ns() { echo $(($($BB date +%s | tr -d '\n') * 1000000000)); }
boottime_ns()  { echo $(( $(cut -d' ' -f1 /proc/uptime | cut -d. -f1) * 1000000000 )); }

report() {
    rt=$(realtime_ns)
    bt=$(boottime_ns)
    echo "$holders" | while read -r hp hcid hfd; do
        [ -n "$hp" ] || continue
        info=$($BB cat "/proc/$hp/fdinfo/$hfd" 2>/dev/null)
        iv=$(echo "$info" | grep '^it_value:' \
             | sed -e 's/it_value: *(//' -e 's/)//' -e 's/,/ /')
        sec=$(echo $iv | cut -d' ' -f1 | tr -cd '0-9')
        nsec=$(echo $iv | cut -d' ' -f2 | tr -cd '0-9')
        [ -n "$sec" ] || continue
        [ "${sec}${nsec}" = "00" ] && continue
        exp=$(( sec * 1000000000 + ${nsec:-0} ))
        if [ "$hcid" = "9" ]; then now=$bt; else now=$rt; fi
        nm=$($BB cat /proc/$hp/comm 2>/dev/null)
        echo $(( (exp - now) / 1000000 )) "$hcid" "$hp" "$nm" "$hfd"
    done
}

# The set of alarm-clock timerfds does not churn, so resolve it once.
holders=$(for p in $(ls /proc | grep -e '^[0-9]' | sort -un); do
    [ -r /proc/$p/fd ] || continue
    for fd in /proc/$p/fd/*; do
        [ -e "$fd" ] || continue
        case "$($BB readlink "$fd" 2>/dev/null)" in *timerfd*) ;; *) continue ;; esac
        info=$($BB cat "/proc/$p/fdinfo/${fd##*/}" 2>/dev/null)
        cid=$(echo "$info" | grep '^clockid:' | tr -cd '0-9')
        case "$cid" in 8|9) echo "$p $cid ${fd##*/}" ;; esac
    done
done)

echo "alarm-clock timerfds held: $(echo "$holders" | grep -c .)"
echo "head_ms cid pid name fd"
elapsed=0
while [ "$elapsed" -lt "$WINDOW" ]; do
    report | sort -n | head -4
    sleep "$STEP"
    elapsed=$((elapsed + STEP))
done
echo "===== done ====="