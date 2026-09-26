# log-tag-mutes

Holds four Android log tags at level `E` (errors only) on the Blackview Shark 8
GSI (Android 13/14 AOSP GSI on the stock vendor image, kernel
`5.10.223-rama982-gki-v1.19-ksu`). Ships as its own KernelSU module,
`log_tag_mutes`, and is one of seven modules of the
[shark8-gsi-logspam-cosmetics](../README.md) project.

This is the module for everything the log level is the correct tool for. What
the level cannot do - ERROR lines that are artifacts of the GSI/vendor mix -
belongs to the binary-patch modules instead, and this module deliberately does
not try to swallow those.

## What it fixes

### 1. ImsProvisioningController: getTechsFromCarrierConfig failed

Every ~30s `com.android.phone` logged W/D spam. Decompiled from the on-device
`TeleService.apk`: `isProvisioningRequired()` calls `getTechsFromCarrierConfig()`,
which looks up the carrier-config bundle `ims.mmtel_requires_provisioning_bundle`
and reads an int-array by capability key. The bundle exists but is empty
(`PersistableBundle[{}]`), so the array is null -> "getTechsFromCarrierConfig
failed" -> provisioning treated as not required.

That fallback is the correct behavior for an operator that does not gate IMS.
It is pure cosmetic noise, so instead of patching the dex we suppress the tag:

    persist.log.tag.ImsProvisioningController E

Takes effect immediately and survives reboot. Revert with an empty value.

### 2. eara_io_service perf_lock_acq spam (libPowerHal, mtkpower_client)

During asset loading, `/vendor/bin/eara_io_service` (MTK EARA-IO QoS) renews a
500 ms `perf_lock_acq` every ~100 ms and floods two tags:

    I mtkpower_client: perf_lock_acq, hdl:78, dur:500, num:10, tid:12490
    D mtkpower_client: [perf_lock_acq] list:0x01408300, 80
    I mtkpower_client: ret_hdl:78
    I libPowerHal: [perfLockAcq] idx:0 hdl:78 hint:-1 pid:1453 duration:500 lock_user:eara_io_service
    I libPowerHal: [PE] eara_io_service update cmd:1408300, param:70

~650 lines per game load (`libPowerHal` 418, `mtkpower_client` 224). The "boost"
itself is only 5 resources - top-app `uclamp.min` floor plus schedutil
up/down-rate limits for 500 ms - so there is nothing worth logging:

| id | PERF_RES_... | value |
|----|--------------|-------|
| 0x01408300 | SCHED_UCLAMP_MIN_TA | 70..100 |
| 0x01438300 / 0x01438400 | SCHED_UTIL_UP_RATE_LIMIT_US_CLUSTER_0/1 | 0 |
| 0x01438600 / 0x01438700 | SCHED_UTIL_DOWN_RATE_LIMIT_US_CLUSTER_0/1 | 100000 us |

Silenced with tag levels in `post-fs-data.sh`:

    persist.log.tag.libPowerHal E
    persist.log.tag.libPowerHal-bt E
    persist.log.tag.mtkpower_client E

`libPowerHal-bt` is the second tag `libpowerhal.so` logs under (the
`libPowerHal-bt` literal at .rodata 0xD48C is used as the tag). Only the BT
low-latency path uses it - a profile with `PERF_RES_NET_BT_AUDIO_LOW_LATENCY`
logs 3 INFO lines per notify (`bt a2dp low latency enter = 1, data:0x..`,
`open provider cb`, `get provider successfully`). A hyphen in a property name is
fine: `setprop persist.log.tag.libPowerHal-bt E` is accepted and the HAL picks
it up immediately (verified: 3 lines -> 0 after `ctl.restart power-hal-1-0`).

Tags containing `@` (`eara_io@boost`, `eara_io@eval`, ~120 lines per load) are
handled by a binary patch instead, in
[`../eara-io-scene-detector/`](../eara-io-scene-detector/README.md).

## Correction: `@` is legal in an Android property name

The earlier claim that `@` is illegal in an Android property name is wrong. The
stock image itself ships `persist.log.tag.mtkpower@impl=I`, and `setprop
persist.log.tag.mtkpower@impl V` + `setprop ctl.restart power-hal-1-0` really
does lift that tag to DEBUG on this device. `persist.log.tag.eara_io@boost=E` /
`...eval=E` would very likely work too, but that has not been re-tested against
the stock `lib_eara_io_scndet.so`, so the verified binary patch stays where it
is. If it is ever re-tested, the two `eara_io@*` tags can move into this module
and the eara_io module can be dropped.

## What this module does NOT do

* It does not silence `E libPowerHal` lines. The level filter only drops INFO
  and below; the recurring ERROR sources (`[getCPUFreq] error cid:2`, the two
  absent foreground-pid nodes, the netdagent dispatch block) are patched in
  [`../libpowerhal-noise/`](../libpowerhal-noise/README.md), because they are
  not log-level artifacts.
* It does not silence the netdagent daemon's own two `E` lines, which come
  from a different file: [`../netdagent-iptables/`](../netdagent-iptables/README.md).
* It does not touch `mtkpower@impl`. The `[setMode] unknown type` line it logs
  is produced by the vendor HAL for a mode it does not implement, and a tag
  mute would not be enough; it is patched in
  [`../mtk-power-setmode/`](../mtk-power-setmode/README.md).

## Files

    module.prop     KernelSU module metadata (id=log_tag_mutes)
    post-fs-data.sh holds the four props at E, before the power HAL starts
    apply.sh        install the module + set the props live
    revert.sh       reset the props to the stock value + remove the module

## Why post-fs-data and not service.sh

The `persist.log.tag.*` props are persistent on their own, so nothing forces a
boot script. It is here anyway for two reasons: the tags have to be in place
*before* the power HAL starts, or the first boot window keeps logging the full
INFO flood; and a ROM flash or a stray `setprop` should not silently undo the
mute. `post-fs-data` is the earliest phase there is, so it wins.

## Install

Option A, KernelSU Manager: flash
`../release/shark8_log_tag_mutes_v1.0.zip`, then reboot.

Option B, in place on a rooted device:

    sh log-tag-mutes/apply.sh

The props are live immediately, no reboot needed.

## Verify

    adb shell getprop persist.log.tag.ImsProvisioningController
    adb shell getprop persist.log.tag.libPowerHal
    adb shell getprop persist.log.tag.libPowerHal-bt
    adb shell getprop persist.log.tag.mtkpower_client

Healthy: all four print `E`. Mute proof, both directions:

    adb shell setprop persist.log.tag.libPowerHal I
    adb shell setprop ctl.restart power-hal-1-0
    # trigger a screen off/on toggle, then:
    adb shell 'logcat -d | grep -c libPowerHal'    # 24 lines with the tag at I
    adb shell setprop persist.log.tag.libPowerHal E
    adb shell setprop ctl.restart power-hal-1-0
    adb shell 'logcat -d | grep -c libPowerHal'    # 0 with the tag at E

For `libPowerHal-bt` specifically: a profile with
`PERF_RES_NET_BT_AUDIO_LOW_LATENCY` gives 0 BT lines at `E` and the 3 INFO
lines come back at `V`, which is what proves the hyphenated property name is
the right knob.

Individual tags can be re-enabled at any time, no reboot needed:

    adb shell setprop persist.log.tag.ImsProvisioningController ""
    adb shell setprop persist.log.tag.libPowerHal ""
    adb shell setprop persist.log.tag.libPowerHal-bt ""
    adb shell setprop persist.log.tag.mtkpower_client ""

## Revert

    sh log-tag-mutes/revert.sh

then reboot to drop the module. Or remove `log_tag_mutes` in the KernelSU
Manager - but reset the props by hand in that case, they are persistent and
outlive the module.

## Verified on device (2026-09-21, v5 / v5.2, pre-split)

- v5 full reboot: all three MTK tags persisted as `E`, crash buffer empty.
- 40 s idle + screen off/on: `libPowerHal` 0 lines, `mtkpower_client` 0 lines,
  `setMode` 2 lines (the legitimate `[setMode] Disable All` / `Restore All`
  from the mode 7 handler, once per screen toggle).
- Mute proof: same screen-toggle trigger with the tags at `I` -> 24
  `libPowerHal` lines, with the tags at `E` -> 0.
- v5.2: with `libPowerHal` at `E` (the shipped state) the net-boost notify
  produced **0** `libPowerHal` lines total. Before that patch the identical
  trigger produced `[NetdAgentCmd] dispatchNetdagentCmd failed` +
  `[netd_set_priority_uid] SetPriorityWithUID fail` - the proof that the tag
  mute alone was not enough and the binary patch was needed.
- `libPowerHal-bt`: tag at `E` -> **0** BT lines; tag at `V` -> the 3 INFO
  lines come back, which proves the tag (and its hyphen) is the right knob.

These measurements were taken while this content was part of the single
`selinux_cosmetics` module; the props and their values are unchanged by the
split.

## Ownership

This subdirectory is the only owner of the `persist.log.tag.*` props in the
project. The four props are one switch each and they all move together, so
keeping them in one module means one boot script and one place to look when a
tag needs to come back up. If a future tag has to be muted with a *binary*
patch instead, it goes into its own module next to the file it patches.
