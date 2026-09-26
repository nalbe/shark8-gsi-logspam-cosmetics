# eara-io-scene-detector

Binary patch of the MTK EARA-IO scene detector on the Blackview Shark 8 running
an Android 13/14 AOSP GSI on the stock vendor image (KernelSU 0.9.4, kernel
`5.10.223-rama982-gki-v1.19-ksu`). It ships as its own KernelSU module,
`eara_io_scene_detector`, and owns exactly one file:
`/vendor/lib64/lib_eara_io_scndet.so`. One of the seven modules of the
[shark8-gsi-logspam-cosmetics](../README.md) project - zero functional change,
zero permissive domains.

## What it fixes

    I eara_io@boost: [eara_io_boost] eara_io_boost 2 , ta 80
    I eara_io@eval:  [eara_io_eval] r2 462 , r 528 , w2 0 , w 0 , w+r 528 , w2+r2 462 , w3+r3 1628

The remaining ~120 lines per game load, on top of the ~650 lines the QoS
renewals cost, come from `lib_eara_io_scndet.so` (scene detector inside
`/vendor/bin/eara_io_service`).

## Root cause

The scene detector logs two INFO tags per asset load, and neither line says
anything an operator could act on. It sits inside the same burst as the rest of
the EARA-IO QoS traffic: during asset loading,
`/vendor/bin/eara_io_service` (MTK EARA-IO QoS) renews a 500 ms `perf_lock_acq`
every ~100 ms and floods two tags:

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

The `libPowerHal` and `mtkpower_client` halves of that burst are plain
log-level artifacts and are muted by tag in
[../log-tag-mutes/](../log-tag-mutes/README.md). The two `eara_io@*` tags are
not - see below.

## Correction: '@' is legal in a property name

The original justification for patching instead of using `persist.log.tag.*`
was wrong. The stock image itself ships `persist.log.tag.mtkpower@impl=I`, and
`setprop persist.log.tag.mtkpower@impl V` + `setprop ctl.restart power-hal-1-0`
really does lift that tag to DEBUG on this device - `@` is legal in an Android
property name, no escaping needed.

So `persist.log.tag.eara_io@boost=E` / `...eval=E` would very likely work too.
That has not been re-tested against the stock `lib_eara_io_scndet.so`, so the
binary patch that *is* verified on device stays until the tag route is
re-tested.

Note the split: [../log-tag-mutes/](../log-tag-mutes/README.md) owns the tag
route for the four tags that do not need patching
(`ImsProvisioningController`, `libPowerHal`, `libPowerHal-bt`,
`mtkpower_client`). This module owns the two `@` tags, by binary patch.

## The patch

`vendor/lib64/lib_eara_io_scndet.so` (19 KB overlay), stock md5
`54218e4a8c26e09645c5d35f622ad4fd` -> patched md5
`71af817be84f670a088ce439db96e18c`.

| file offset | stock | patched | effect |
|-------------|-------|---------|--------|
| 0x358C | `0x940000A9` `bl __android_log_print` | `0xD503201F` `nop` | drops `eara_io_boost 0 , ta 0` (level-0 / reset path, the bulk of the flood) |
| 0x3688 | `0x9400006A` `bl __android_log_print` | `0xD503201F` `nop` | drops `eara_io_boost %d , ta %d` (levels 1..4) |
| 0x2CF8 | `0x940002CE` `bl __android_log_print` | `0xD503201F` `nop` | drops `[eara_io_eval] r2 %d , ...` |

Only the three INFO calls are dropped: every state update before them stays, and
the ERROR paths of the same functions (`[%s] no data found`, `perfLockAcq error`,
`dlopen fail`, `notify: acq perf_hdl`) keep logging. `patch_libeara.ps1`
validates both format strings, both tag strings and four context instructions
before patching.

## Reproducing the spam without a game

Reproducing the spam without a game is possible with
`tools/eara_boost_probe.c`: it dlopens the library and calls its exported
`eara_io_boost(int)`, which is exactly what the scene detector calls.

    android-sdk\...\clang --target=aarch64-linux-android21 ^
        --sysroot=<ndk>\toolchains\llvm\prebuilt\windows-x86_64\sysroot ^
        -fPIE -pie -O2 -o eara_boost_probe eara-io-scene-detector\tools\eara_boost_probe.c
    adb push eara_boost_probe /data/local/tmp/ && adb shell chmod 755 /data/local/tmp/eara_boost_probe
    adb shell 'logcat -c; /data/local/tmp/eara_boost_probe 3; logcat -d | grep eara_io@'

The built binary is checked in as `tools/eara_boost_probe`, so it can be pushed
as-is (see Verify).

Caveat: the probe runs in the `su` domain, so its perf lock additionally produces
`E libPowerHal: Could not open '/proc/<pid>/comm'` plus a handful of
`mtk_hal_power -> su` proc denials. That is a probe artifact - a real app
requests locks from `untrusted_app`/`priv_app`, which are already readable.

## Files

    module.prop     KernelSU module metadata (id: eara_io_scene_detector)
    apply.sh        install the module + print the payload md5
    revert.sh       remove the module
    post-fs-data.sh relabel the overlay payload to vendor_file
    patch_libeara.ps1
                    host-side: rebuild the patched lib_eara_io_scndet.so from
                    the stock library
    vendor/lib64/lib_eara_io_scndet.so
                    patched eara_io scene detector (INFO firehose fix)
    tools/eara_boost_probe.c
                    device-side trigger for the eara_io INFO logs
    tools/eara_boost_probe
                    prebuilt probe binary, same purpose

The two `tools/` entries are a verification tool, not module files: they are not
copied by `apply.sh` and not in the release zip.

## Overlay labels

A zip install used to leave the payload labeled `u:object_r:system_file:s0`
instead of the stock `vendor_file`: `ksud module install` extracts zip payloads
with that context, and KernelSU mounts the `/vendor` overlay with `seclabel`, so
the linker sees the replacement library with the wrong label. `eara_io` is only
granted `vendor_file`, so `eara_io_service` was denied on its own library and
crash-looped on it every 5 s - the logspam this module removes, replaced by a
linker failure loop. `post-fs-data.sh` chcon's the module's own `vendor/` tree on
every boot, which is what `apply.sh` always did for manual installs. See
[../mtk-power-setmode](../mtk-power-setmode/README.md) for the full incident -
there the same label bootlooped the device outright.

## Install

Option A, KernelSU Manager: flash
`../release/shark8_eara_io_scene_detector_v1.0.zip` (module.prop at the zip
root, same flat layout as the other release zips in this project), then reboot.

Option B, in place on a rooted device:

    sh eara-io-scene-detector/apply.sh
    adb reboot

`/vendor` is never written. The patched library is a KernelSU overlay mounted
over the stock one, so it is live only after the reboot.

## Verify

After the reboot, the overlay md5 must be the patched one:

    adb shell md5sum /vendor/lib64/lib_eara_io_scndet.so
    71af817be84f670a088ce439db96e18c  (stock is 54218e4a8c26e09645c5d35f622ad4fd, 19808 bytes)

Then the probe, before and after:

    adb push eara-io-scene-detector/tools/eara_boost_probe /data/local/tmp/ && adb shell chmod 755 /data/local/tmp/eara_boost_probe
    adb shell 'logcat -c; /data/local/tmp/eara_boost_probe 3; logcat -d | grep eara_io@'

Unpatched: 4 probe calls produce 4 `eara_io@boost` lines (`1 , ta 70`,
`2 , ta 80`, `3 , ta 80`, `0 , ta 0`). After the patch and a reboot: the same 4
calls give **0** `eara_io@boost`, **0** `eara_io@eval`, **0**
`eara_io@idxcollector`.

## Revert

    sh eara-io-scene-detector/revert.sh
    adb reboot

or remove `eara_io_scene_detector` in the KernelSU Manager and reboot. The stock
library comes back with the overlay gone; the other modules of the project are
untouched.

## Rebuilding the payload

    adb pull /vendor/lib64/lib_eara_io_scndet.so stock-scndet.so
    powershell -File eara-io-scene-detector\patch_libeara.ps1 -In stock-scndet.so -Out patched-scndet.so

The script fails loudly if the input is not the expected stock build (it checks
the stock md5/size, both format strings, both tag strings and the surrounding
instructions), so a vendor update cannot be patched by accident.

The probe, from the checked-in source:

    android-sdk\...\clang --target=aarch64-linux-android21 ^
        --sysroot=<ndk>\toolchains\llvm\prebuilt\windows-x86_64\sysroot ^
        -fPIE -pie -O2 -o eara_boost_probe eara-io-scene-detector\tools\eara_boost_probe.c

## Verified on device (2026-09-21, v5, pre-split)

- Section 8 patch verified with `tools/eara_boost_probe` (calls the exported
  `eara_io_boost(int)` directly, which is what the scene detector does):
  unpatched library -> 4 probe calls produced 4 `eara_io@boost` lines
  (`1 , ta 70`, `2 , ta 80`, `3 , ta 80`, `0 , ta 0`); after the patch and a
  reboot -> same 4 calls, **0** `eara_io@boost`, 0 `eara_io@eval`, 0
  `eara_io@idxcollector`.
- Provenance: that measurement was taken when this patch was section 8 of the
  single combined `selinux_cosmetics` module; the payload md5
  `71af817be84f670a088ce439db96e18c` is identical to the one verified in v5.3.

## Ownership

This subdirectory is the only owner of `/vendor/lib64/lib_eara_io_scndet.so` in
the project. Two KernelSU modules must never overlay the same file, so any
further binary change to the eara_io scene detector belongs here.
