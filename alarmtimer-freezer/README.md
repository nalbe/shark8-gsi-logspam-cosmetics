# alarmtimer-freezer

Fix for the endless suspend-abort storm on the Blackview Shark 8 GSI (Android 13
AOSP GSI on the stock vendor image, kernel `5.10.223-rama982-gki-v1.19-ksu`).
Ships as its own KernelSU module, `alarmtimer_freezer_off`, and belongs to the
[shark8-gsi-logspam-cosmetics](../README.md) project - same device, same GSI/vendor
mix, but a different subsystem (power/suspend instead of log levels), so it stays
in a separate module directory instead of touching `selinux_cosmetics`.

## What it fixes

    E alarmtimer.1.auto: PM: failed to suspend: error -16
    I Abort: Device alarmtimer.1.auto failed to suspend: error -16
    I [C700000] [name: spm&] Pending Wakeup Sources: alarmtimer.1.auto

`-16` is `EBUSY`. On this device it fired 12-15 times per minute, **every** s2idle
attempt was aborted, the wakeup counter for `alarmtimer.1.auto` climbed without
stopping (142 -> 148 while idle), and the phone never reached deep sleep - the
battery drain that made the other cosmetic patches in this project worth doing
in the first place.

## Root cause

The device is the RTC alarmtimer, a child of the MT6358 RTC:

    /sys/bus/platform/devices/alarmtimer.1.auto
    /sys/bus/platform/drivers/alarmtimer            (built into the kernel image)
    .../soc/10026000.pwrap/.../mt6358-rtc/rtc/rtc0/alarmtimer.1.auto/

Its suspend callback refuses to let the system sleep while the next alarm is
close, because the RTC would have to be reprogrammed mid-flight
(`kernel/time/alarmtimer.c`, MTK 5.10 tree):

    if (ktime_to_ns(min) < 2 * NSEC_PER_SEC) {
            pm_wakeup_event(dev, 2 * MSEC_PER_SEC);
            return -EBUSY;
    }

`min` is the earliest expiry in the alarm clock's timerqueue (REALTIME or
BOOTTIME). So the abort means: **some process holds an alarm-clock timer that is
overdue or less than 2 s away, and it is never consumed.**

The app-freezer is what makes that permanent. With `use_freezer=true`,
CachedAppOptimizer freezes cached app cgroups; a frozen task cannot run, so it
cannot consume its timerfd expiry nor re-arm a periodic alarm. Its
`k_itimer` stays in the queue with a stale `expires`, `alarmtimer_suspend()`
sees a sub-2 s head, aborts, the device stays awake, so the cgroup is never
thawed - and the daemon never gets the idle window in which it would thaw. A
self-sustaining loop.

Trace evidence for the stale timers (ftrace `alarmtimer` events, 60 s window,
screen off): repeated `alarmtimer_fired` with `expires` in the past by
0.075 ms, 0.758 ms and 3.7 ms, plus constant `alarmtimer_start` /
`alarmtimer_cancel` churn from `system_server` and `bt_stack_manage`.

## The fix

    device_config put activity_manager_native_boot use_freezer false

and clear the damage done during the current boot:

    for f in $(find /sys/fs/cgroup -maxdepth 3 -name cgroup.freeze); do echo 0 > $f; done

The DeviceConfig value persists by itself (it lives in the DeviceConfig DB, it
survives reboots - verified). The module re-asserts it every boot only to
survive an OTA/ROM that resets the DB.

**One reboot is required after a live install.** CachedAppOptimizer reads the
flag exactly once, in its constructor, and the DeviceConfig service is hosted by
system_server - so a `put` from a late-start script always lands after that
read and only takes effect on the next boot. `apply.sh` says so and ends with the
reboot hint. On the very first boot after a ROM flash, run `thaw.sh thaw` again
(or just reboot twice) if cgroups are still frozen.

## Measured on device (2026-09-26, screen off, `mWakefulness=Dozing`)

| | before | after |
|---|---|---|
| `alarmtimer.1.auto` aborts | 12-15 /min, 100% of suspend attempts | **1.3 /min** (50 aborts over 37 min uptime) |
| wakeup counter | climbing continuously (142 -> 148 while idle) | flat for 60-80 s stretches |
| frozen cgroups | 100+ (`/sys/fs/cgroup/uid_*/pid_*`) | 0, and stays 0 |
| suspend attempts | every attempt aborted | ~16% abort, the rest sleep |
| battery, 10 min screen off | draining | 93% -> 93% |
| deep doze | never reached | 15 min, 0 mAh |

Bluetooth off made no difference (still 4 aborts/45 s), so it is not the BT
stack's timers.

## Cost

Cached background apps are no longer frozen: they keep running and cost a few
extra idle wakeups with the screen on. That is the intended trade - on this
device the freezer was not saving battery, it was preventing the much larger win
(deep sleep). `revert.sh` puts the stock value back in one command.

## Deliberately not done

* **Unbinding `alarmtimer.1.auto`** (`echo alarmtimer.1.auto > /sys/bus/platform/drivers/alarmtimer/unbind`)
  would silence the storm permanently, but that device *is* the RTC wakeup
  programmer: RTC-based `AlarmManager` wakeups and the alarm clock stop working
  after suspend. Not worth it now that the actual cause is fixed.
* **`/proc/<pid>/timers`** does not exist on this kernel, and reading another
  process's `/proc/<pid>/fdinfo/<fd>` for a timerfd returns `ENXIO`, so the
  owning process of the stale timer could not be named from userspace. It does
  not matter any more: the mechanism is identified and the trigger is off.
* No kernel patch, no `unbind`, no property that fakes the absence of the
  device - the fix is the one framework flag that actually controls the behavior.

## Residual noise (not the alarmtimer, not fixed here)

* `WLAN timeout` / `WLAN Timer` wakeups: the vendor WLAN driver's keepalive
  timer wakes the device about every 6 s, which is what most of the remaining
  `Some devices failed to suspend, or early wake event detected` lines are.
  Worth a separate investigation; it needs WiFi off to A/B test, which cannot be
  done over an adb-over-WiFi session.
* Top of `/sys/kernel/debug/wakeup_sources` by active count on this build:
  `mt635x-auxadc` (67321), a stale `deleted` source (41202 - a vendor HAL that
  unlinked and left its wakeup source behind), `battery` (3948). All vendor-side,
  none of them abort the suspend.
* With the alarmtimer quiet, `libPowerHal`/`mtkpower_client`/netdagent and the
  avc noise are what is left - that is the rest of this project.

## Files

    module.prop     KernelSU module metadata (id: alarmtimer_freezer_off)
    service.sh      boot-time enforcer: assert the flag, thaw, one summary line
    thaw.sh         thaw|count|list - inspect and clear the freezer state
    measure.sh      [seconds] [step] - abort rate from the wakeup counter
    whoblocks.sh    [seconds] - who aborts suspend, what wakes the device
    findfrozen.sh   list frozen cgroups with their pids
    apply.sh        install the module + live apply
    revert.sh       restore use_freezer=true, thaw, remove the module

## Install

Option A, KernelSU Manager: flash
`../release/shark8_alarmtimer_freezer_off_v1.0.zip` (6981 bytes, md5
`0d5d60b4ed13e2a14478830098dede8f`; module.prop at the zip root, same flat
layout as the other release zips in this project), then reboot.

Option B, in place on a rooted device:

    sh alarmtimer-freezer/apply.sh
    adb reboot

Option C, no module at all, just the fix:

    adb shell device_config put activity_manager_native_boot use_freezer false
    adb shell 'for f in $(find /sys/fs/cgroup -maxdepth 3 -name cgroup.freeze); do echo 0 > $f; done'
    adb reboot

## Verify

    adb root
    adb shell sh /data/adb/modules/alarmtimer_freezer_off/measure.sh 180
    adb shell sh /data/adb/modules/alarmtimer_freezer_off/whoblocks.sh 150
    adb shell sh /data/adb/modules/alarmtimer_freezer_off/findfrozen.sh

Healthy: the alarmtimer counter is flat for long stretches, `frozen count: 0`,
and `ebusy` stays 0 or near it; `dpm callback failures` lists nothing but
occasional `alarmtimer.1.auto` aborts at wake boundaries. Broken: the counter
climbs on every sample, `frozen count` is 100+ and `ebusy` matches the number of
suspend entries.

## Revert

    sh alarmtimer-freezer/revert.sh
    adb reboot

or remove `alarmtimer_freezer_off` in the KernelSU Manager and reboot (the flag
in the DeviceConfig DB has to be put back to `true` separately, otherwise the
freezer stays off).

## Diagnostics used to get here

* `logcat`/`dmesg`: the abort lines, `Pending/Last active Wakeup Sources`.
* `/sys/kernel/debug/wakeup_sources`: the `alarmtimer.1.auto` wakeup counter
  (the exact abort counter - it only moves on a real `-EBUSY`).
* ftrace `alarmtimer` class: `alarmtimer_start` / `alarmtimer_cancel` /
  `alarmtimer_fired` with `expires` vs `now`, showing the stale BOOTTIME expiries.
* `signal_generate` tracepoint filtered to `sig == 14` (SIGALRM): **0** hits in
  30 s, which ruled out a live POSIX timer being signalled and pointed at frozen
  tasks whose timers are never consumed.
* cgroup v2 `cgroup.events` / `cgroup.freeze` across `/sys/fs/cgroup/uid_*` and
  `/sys/fs/cgroup/uid_*/pid_*` (255 freezer files on this device).
* A/B with `use_freezer` toggled and a full thaw, plus the same A/B with
  Bluetooth off, which changed nothing.
