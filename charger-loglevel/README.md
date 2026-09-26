# charger-loglevel

Silences the MTK charger driver's own printk on the Blackview Shark 8 GSI by
writing `0` to its runtime log-level knob. No binary is patched, nothing outside
sysfs is touched, revert = delete the module.

Module id `charger_loglevel`, part of
[shark8-gsi-logspam-cosmetics](../README.md). Split out of the old combined
`shark8_quietlogs` module, which wrote this node from the same `service.sh` as
[`wlan-loglevel`](../wlan-loglevel) and
[`gauge-loglevel`](../gauge-loglevel).

## Payload

| node | stock | set to | lifetime |
|---|---|---|---|
| `/sys/devices/platform/charger/charger_log_level` | driver default (not recorded, see below) | `0` | runtime only, re-asserted every boot by `post-fs-data.sh` |

It is a driver module parameter, so the value is gone after every reboot.
`post-fs-data.sh` runs once at every boot and returns immediately - the charger
platform device is up long before anything interesting logs, and a polling loop
there would stall the other modules.

## What this does NOT fix, and why

### `sgm4154x_dump_register` (~4 lines/s)

SGM4154x is the charger IC, and this is the driver dumping its registers
`0x0..0xf` over I2C, 16 lines per pass, driven by `charger_monitor_work_func`
(XRCharge). It survives every log-level knob:

- `charger_log_level` = 0 and = 2, no change in the dump rate
- `battery/log_level` was already 0
- `FG_daemon_log_level` = 0, no effect (that knob belongs to
  [`gauge-loglevel`](../gauge-loglevel))

Because `sgm415xx` and `mt6358_battery` are **built into vmlinux**.
`grep -rls sgm4154x_dump_register` across all 181 modules in `/vendor_dlkm`
returns nothing, so there is no file to patch. The remaining fix is a vmlinux
binary patch (NOP the `printk` in that function), which needs the kernel image
out of `vendor_boot`/`boot` and a matching vmlinux analysis. Not done here.

It is also charge-state driven: with the battery at 100% and the reported
current oscillating around zero (`current = -20 / -12 / +96` mA), every state
change triggers a new dump. Unplugging the cable removes most of it.

**So this module has no measured win of its own.** It is here because it is a
real driver knob that costs nothing, but if you are chasing the register dump,
this is not what stops it.

## Why the stock value is not in the table

The old combined `shark8_quietlogs` module had already set the node to `0`
before this module was split out, so the stock value was never observed on a
device that had not already been touched. Rather than guess, `revert.sh` removes
the module and reboots, which restores the driver default by itself.

## Install

Flash `release/shark8_charger_loglevel_v1.0.zip`, or install in place:

    sh charger-loglevel/apply.sh

If the old combined module is still installed, remove it - it writes the same
node:

    adb shell su -c 'rm -rf /data/adb/modules/shark8_quietlogs'

## Verify

    adb shell cat /sys/devices/platform/charger/charger_log_level    # 0
    adb shell cat /data/local/tmp/charger_loglevel.log

## Revert

    sh charger-loglevel/revert.sh
    adb reboot

Nothing is written back on the spot: the value is runtime-only and the next boot
returns it to the driver default.
