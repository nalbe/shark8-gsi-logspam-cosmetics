# gauge-loglevel

Silences the MT6358 fuel gauge driver's own printk on the Blackview Shark 8 GSI
by writing `0` to its runtime log-level knob. No binary is patched, nothing
outside sysfs is touched, revert = delete the module.

Module id `gauge_loglevel`, part of
[shark8-gsi-logspam-cosmetics](../README.md). Split out of the old combined
`shark8_quietlogs` module, which wrote this node from the same `service.sh` as
[`wlan-loglevel`](../wlan-loglevel) and
[`charger-loglevel`](../charger-loglevel).

## Payload

| node | stock | set to | lifetime |
|---|---|---|---|
| `.../10026000.pwrap:mt6366/mt6358-gauge/FG_daemon_log_level` | driver default (not recorded, see below) | `0` | runtime only, re-asserted every boot by `post-fs-data.sh` |

Full path, note the `:` in the pwrap node name - quote it in shell:

    /sys/devices/platform/soc/10026000.pwrap/10026000.pwrap:mt6366/mt6358-gauge/FG_daemon_log_level

It is a driver module parameter, so the value is gone after every reboot.
`post-fs-data.sh` runs once at every boot and returns immediately - the pwrap
gauge device is up early, and a polling loop there would stall the other
modules.

## What this does NOT fix, and why

`sgm4154x_dump_register` (~4 lines/s) is the SGM4154x charger IC dumping its
registers `0x0..0xf` over I2C, driven by `charger_monitor_work_func`. Setting
`FG_daemon_log_level` to 0 changes nothing about it: that function belongs to
the charger driver, and `sgm415xx` / `mt6358_battery` are built into vmlinux,
so there is no `.ko` to patch (`grep -rls sgm4154x_dump_register` across all 181
modules in `/vendor_dlkm` returns nothing). The only fix is a vmlinux binary
patch. See [`charger-loglevel`](../charger-loglevel/README.md) for the full
write-up, and note that the dump is charge-state driven and goes quiet off
charge.

`battery/log_level` was already 0 on the stock image, so there is nothing to do
there either.

**So this module has no measured win of its own.** It is a real driver knob
that costs nothing, but it is not what stops the register dump.

## Why the stock value is not in the table

The old combined `shark8_quietlogs` module had already set the node to `0`
before this module was split out, so the stock value was never observed on a
device that had not already been touched. Rather than guess, `revert.sh` removes
the module and reboots, which restores the driver default by itself.

## Install

Flash `release/shark8_gauge_loglevel_v1.0.zip`, or install in place:

    sh gauge-loglevel/apply.sh

If the old combined module is still installed, remove it - it writes the same
node:

    adb shell su -c 'rm -rf /data/adb/modules/shark8_quietlogs'

## Verify

    adb shell cat /sys/devices/platform/soc/10026000.pwrap/10026000.pwrap:mt6366/mt6358-gauge/FG_daemon_log_level
    adb shell cat /data/local/tmp/gauge_loglevel.log

## Revert

    sh gauge-loglevel/revert.sh
    adb reboot

Nothing is written back on the spot: the value is runtime-only and the next boot
returns it to the driver default.
