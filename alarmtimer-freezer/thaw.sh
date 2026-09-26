#!/system/bin/sh
# thaw.sh [thaw|count|list] - inspect and clear cgroup freezer state.
#
# Android's app-freezer is the root cause of the alarmtimer suspend-abort storm
# (see README.md). Turning the flag off stops NEW freezes; this script clears the
# cgroups that are ALREADY frozen, which is what makes a live fix effective
# without waiting for a reboot.
#
#   thaw    write 0 to every cgroup.freeze, print how many writes succeeded and
#           how many cgroups are still frozen
#   count   print the number of frozen cgroups (0 = clean)
#   list    print each frozen cgroup, its pids and their comm/state
#
# Depth 3 covers the Android layout: /sys/fs/cgroup/uid_<N>/cgroup.freeze and
# /sys/fs/cgroup/uid_<N>/pid_<M>/cgroup.freeze (255 files on this device).
# /sys/fs/cgroup itself has no cgroup.freeze on this build, and the root write
# is denied, so it is simply absent from the find output.
#
# A cgroup reports "frozen 1" in cgroup.events if IT OR ANY DESCENDANT is frozen,
# so count/list are recursive by nature - thawing the uid_* parent alone is not
# enough, the pid_* leaves have to be thawed too.

CGROUP_ROOT=/sys/fs/cgroup

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

list_frozen() {
    for f in $(find "$CGROUP_ROOT" -maxdepth 3 -name cgroup.events 2>/dev/null); do
        grep -q 'frozen 1' "$f" 2>/dev/null || continue
        d=${f%/cgroup.events}
        echo "FROZEN $d"
        for p in $(cat "$d/cgroup.procs" 2>/dev/null); do
            echo "   pid=$p comm=$(cat /proc/$p/comm 2>/dev/null) state=$(awk '{print $3}' /proc/$p/stat 2>/dev/null)"
        done
    done
}

case "${1:-thaw}" in
    thaw)
        n=$(thaw_all)
        echo "thawed $n cgroup.freeze files, frozen left: $(count_frozen)"
        ;;
    count)
        count_frozen
        ;;
    list)
        list_frozen
        echo "---- frozen count: $(count_frozen)"
        ;;
    *)
        echo "usage: $0 [thaw|count|list]" >&2
        exit 1
        ;;
esac
