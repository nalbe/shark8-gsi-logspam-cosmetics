#!/system/bin/sh
# findfrozen.sh - list the cgroups the app-freezer has frozen, with their processes.
#
# Usage on device (as root):
#   sh findfrozen.sh
#
# Note: state=S with a frozen cgroup is normal, it just means the task is
# stopped, not that it is in uninterruptible sleep. Use the freezer count, not
# the process state, as the signal.

CGROUP_ROOT=/sys/fs/cgroup

for f in $(find "$CGROUP_ROOT" -maxdepth 3 -name cgroup.events 2>/dev/null); do
    grep -q 'frozen 1' "$f" 2>/dev/null || continue
    d=${f%/cgroup.events}
    echo "FROZEN $d"
    for p in $(cat "$d/cgroup.procs" 2>/dev/null); do
        echo "   pid=$p comm=$(cat /proc/$p/comm 2>/dev/null) state=$(awk '{print $3}' /proc/$p/stat 2>/dev/null)"
    done
done

echo "---- frozen count: $(find "$CGROUP_ROOT" -maxdepth 3 -name cgroup.events -exec cat {} \; 2>/dev/null | grep -c 'frozen 1')"
