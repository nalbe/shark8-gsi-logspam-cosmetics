# diagnostics

Not a module, not flashed. These are the scripts used to investigate the
`alarmtimer.1.auto: PM: failed to suspend: error -16` suspend-abort storm, kept
because the storm is not explained and these are what measured it.

Run them on the device as root (`adb root`, then `adb shell sh <script>`).

## What was established

The `alarmtimer_freezer_off` module that used to live in this project as
`alarmtimer-freezer/` claimed the Android app-freezer caused the storm and
turned it off. Measurements on 2026-10-04 do not support that:

* With the freezer **on** (41-46 frozen cgroups) and the phone in `mWakefulness=Dozing`,
  `measure.sh` logged **0 aborts in 242 s**.
* All 41 frozen processes hold **zero** timerfds. There is no expiry for a
  frozen task to strand, so the proposed mechanism has no carrier.
* The DeviceConfig route the module used is inert by construction: AConfig
  re-exports the compiled-in flag defaults into
  `persist.device_config.aconfig_flags.*` at the moment the value is latched, so
  a write from `post-fs-data.sh` cannot win. `device_config get` also does not
  change at runtime, so nothing can be A/B-tested without a reboot.

## What was found instead

`headroom.sh` lists every timerfd on an **alarm** clock - `clockid` 8
(`CLOCK_REALTIME_ALARM`) or 9 (`CLOCK_BOOTTIME_ALARM`) - and prints how far its
deadline is from now. Those are the only clocks routed through the kernel
alarmtimer, i.e. the only ones that can make `alarmtimer_suspend()` return
`-EBUSY`.

On this device they are **continuously overdue by 25 ms .. 2.1 s** and never
read:

    -25 ms    droid.bluetooth  fd 193
    -132 ms   droid.bluetooth  fd 341
    -363 ms   system_server    fd 223
    -1154 ms  health@2.1-serv fd 8
    -2147 ms  droid.bluetooth  fd 193

Two of the bluetooth timers are **periodic** (`it_interval` 3600 s and 21600 s).
A periodic alarmtimer re-arms into the kernel timerqueue as soon as it fires, so
a fired-but-unread one sits there with a deadline permanently in the past. That
matches the MTK guard that rejects any alarm closer than 2 s with `-EBUSY`.

Not yet established: which alarmtimer base corresponds to `alarmtimer.1.auto`,
i.e. which of the holders the abort is actually charged to. Settling it needs
the abort counter and the timer headroom sampled in the same instant.

## fdinfo on this kernel

Readable as root, no `ENXIO`. The deadline is in `it_value`, not `expires`, and
`clockid` identifies the clock:

    clockid 0 CLOCK_REALTIME          7 CLOCK_BOOTTIME
    clockid 1 CLOCK_MONOTONIC         8 CLOCK_REALTIME_ALARM
    clockid 4 CLOCK_MONOTONIC_RAW     9 CLOCK_BOOTTIME_ALARM

A disarmed timer reports `it_value: (0, 0)` and is not a candidate. Compare
`clockid` 9 against `/proc/uptime` (boottime) and `clockid` 8 against the wall
clock.

## Files

    headroom.sh    [seconds] [step] - alarm-clock timerfds and their head, 4 closest
    measure.sh     [seconds] [step] - abort rate from the alarmtimer wakeup counter
    whoblocks.sh   [seconds] - who aborts suspend, what wakes the device
    findfrozen.sh  list frozen cgroups with their processes