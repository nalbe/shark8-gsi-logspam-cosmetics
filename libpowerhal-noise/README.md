# libpowerhal-noise

Cosmetic binary patch for the Blackview Shark 8 running an Android 13/14 AOSP GSI
on the stock vendor image (KernelSU 0.9.4, kernel
`5.10.223-rama982-gki-v1.19-ksu`). It silences recurring sources of logspam caused
by GSI/vendor mixing, with zero functional change and zero permissive domains.

This module owns `/vendor/lib64/libpowerhal.so` and nothing else. It is the
biggest of the seven modules of the
[shark8-gsi-logspam-cosmetics](../README.md) project: one library, three separate
ERROR sources.

## What it fixes

### (a) cluster 2 error

    E libPowerHal: [getCPUFreq] error cid:2, nClusterNum:2

~10 lines per game load and once per screen off/on. `getCPUFreq(int cid, int opp)`
returns -1 when `cid < 0 || cid >= nClusterNum`, and something on this 2-cluster
MT6789 still asks for cluster 2 (a leftover entry from 3-cluster SoCs). The -1 is
the vendor's normal "skip this update" path - the request is a no-op - so only the
log call is dropped, the return value and every other error path stay.

### (b) missing kernel nodes (v5.1)

    E libPowerHal: Could not open '/proc/driver/thermal/ta_fg_pid'
    E libPowerHal: error : 2, No such file or directory
    E libPowerHal: Could not open '/sys/module/ged/parameters/gx_top_app_pid'
    E libPowerHal: error : 2, No such file or directory

4 lines per `notifyAppState` (i.e. per game start, and retried on every `state=1`).
`perfNotifyAppState(pack, act, state, pid, uid)` @ .text 0x23D20 hands the
foreground app pid to the two kernel interfaces behind the vendor's per-app
policy:

| addr | instruction | target |
|------|-------------|--------|
| 0x24348 | `add x0, x0, #0x287` | `/proc/driver/thermal/ta_fg_pid` |
| 0x24370 | `add x0, x0, #0x2a6` | `/sys/module/ged/parameters/gx_top_app_pid` |

then `bl set_value(char const*, int)` (0x24350 / 0x24378) and, on success, sets an
"already written" byte (0x2435C / 0x24384) so the write is not retried. Both nodes
are absent from this kernel: the MTK procfs thermal controller is not built at all
(`/proc/driver` has no `thermal`; the kernel uses the generic Linux thermal
framework, 35 zones) and this GED generation (`/sys/module/ged` is loaded) exposes
no pid parameter. Neither node can be created from userspace, so the per-app
thermal/GED hint is dead on this kernel either way.

### (c) netdagent error block (v5.2)

    E libPowerHal: [NetdAgentCmd] dispatchNetdagentCmd failed
    E libPowerHal: [netd_set_priority_uid] SetPriorityWithUID fail

2-4 lines per net-boost notify, on every whitelist entry that carries the
`PERF_RES_NET_*` resources (sgame-style profiles; the profile in use here has
none, which is why this block was the last one left). `netd_*` /
`sdk_netd_*` forward the per-app network hints to the vendor netdagent service,
and on this GSI/vendor mix every call fails: `/vendor/etc/init/netdagent.rc` has
its `socket netdagent stream 0660 root system` line commented out, so the daemon
comes up without a socket, the dispatch returns -1 and the library logs ERROR
from 8 call sites. The `E`-level `[NetdAgentCmd] netdagent firewall ...` DEBUG
line above each failure is below the tag level and never shows.

## The patch

### (a) one nop in the getCPUFreq error path

| file offset | stock | patched | effect |
|-------------|-------|---------|--------|
| 0x281E0 | `0x94005BCC` `bl __android_log_print` | `0xD503201F` `nop` | drops the ERROR line; `0x281E4 b 0x28210` still returns -1 |

### (b) the two path literals repointed at /dev/null

Fix: repoint both `.rodata` path literals at `/dev/null`. `open()` succeeds, the
write is discarded, `set_value()` returns 0, the retry flag is set and nothing is
logged. No behavior change (the writes could never succeed).

| file offset | stock | patched | effect |
|-------------|-------|---------|--------|
| 0x12287 | `/proc/driver/thermal/ta_fg_pid` | `/dev/null` (NUL-padded) | thermal fg-pid write becomes a successful no-op, no ERROR line |
| 0x122A6 | `/sys/module/ged/parameters/gx_top_app_pid` | `/dev/null` (NUL-padded) | GED top-app-pid write becomes a successful no-op, no ERROR line |

### (c) the 8 netdagent log calls nop'ed

Fix: nop the 8 `bl __android_log_print` calls. Every site falls through to code
that sets `w0` explicitly (`wzr` or `-1`), so no register or control flow the
caller can observe changes - the error returns themselves stay.

| file offset | stock | patched | message dropped |
|-------------|-------|---------|-----------------|
| 0x32FC8 | `0x94003052` | `nop` | `[NetdAgentCmd] dispatchNetdagentCmd failed` / `... is not ok` |
| 0x333C0 | `0x94002F54` | `nop` | `[netd_set_priority_uid] SetPriorityWithUID fail` / `[%s] sprintf fail` |
| 0x33428 | `0x94002F3A` | `nop` | `[netd_set_priority_uid] Set packet Priority UID(%d) fail: no more empty slot` |
| 0x33538 | `0x94002EF6` | `nop` | `[netd_clear_priority_uid] ClearPriorityWithUID fail` |
| 0x33EB4 | `0x94002C97` | `nop` | `[sdk_netd_set_priority_by_uid] SetPriorityWithUID fail` |
| 0x33F98 | `0x94002C5E` | `nop` | `[sdk_netd_clear_priority_by_uid] ClearPriorityWithUID fail` |
| 0x340B8 | `0x94002C16` | `nop` | `[sdk_netd_set_priority_by_linkinfo] ... NetdAgentCmd fail` |
| 0x341D8 | `0x94002BCE` | `nop` | `[sdk_netd_clear_priority_by_linkinfo] ... NetdAgentCmd fail` |

`patch_libpowerhal.ps1` also checks all 10 netd format literals, decodes each
`bl` imm26 and requires the target to be `__android_log_print@plt` (0x3F110)
before writing the nop.

Only the logging is removed here: the dispatch still returns -1 and the daemon
still never gets the net hints. The daemon's own two lines
(`E NetdagentIptables: exec() res=0, status=256` and
`E NetdagentService: run command firewall failed`) come from a different file,
`/vendor/bin/netdagent` - a real `iptables` failure, and a separate module of this
project: [`netdagent-iptables/`](../netdagent-iptables/README.md).

### Payload and validation

`libpowerhal-noise/vendor/lib64/libpowerhal.so` (275 KB overlay), stock md5
`eb618de9c44807d6ec1b21eb47ee5eb0` -> patched md5
`58bd610b542ba4ca0747718d1189312a` (v5.1 md5 was
`177293a06360341c478ce6c8886bcc5e`, v5 md5
`fc650d79c5eeaa247d3a4d5a34158bf2`).

This is a separate library from the patched power HAL service library, so the
`libPowerHal` tag stays at `E` and real `libPowerHal` errors keep printing.
`patch_libpowerhal.ps1` rebuilds it and validates the fmt string, three
surrounding instructions, both path literals and their NUL terminators before
touching anything.

## Cost / limits

Both literals are referenced exactly once in the whole library (checked with
`llvm-objdump -d`), so nothing else is affected - and unlike nop'ing
`set_value()`'s log calls, the `/dev/null` repoint keeps the diagnostics of every
other node write intact. The nop'ed netd log calls likewise keep every other
diagnostic of those functions.

The `/dev/null` repoint is the one real cost: if a future kernel does grow these
two nodes, the per-app thermal/GED hint stays off. Neither node can be created
from userspace on this build, so on this build there is nothing to lose.

## Files

    module.prop                  KernelSU module metadata (id: libpowerhal_noise)
    apply.sh                     install the module + print the payload md5
    revert.sh                    remove the module
    post-fs-data.sh              relabel the overlay payload to vendor_file
    patch_libpowerhal.ps1        host-side: rebuild the patched libpowerhal.so
    vendor/lib64/libpowerhal.so  patched MTK powerhal (getCPUFreq ERROR line
                                 dropped + absent fg-pid nodes repointed at
                                 /dev/null + netdagent error block nop'ed)

## Overlay labels

A zip install used to leave the payload labeled `u:object_r:system_file:s0`
instead of the stock `vendor_file`: `ksud module install` extracts zip payloads
with that context, and KernelSU mounts the `/vendor` overlay with `seclabel`, so
the linker sees the replacement library with the wrong label. Vendor domains are
only granted `vendor_file` and can be denied on it.
`post-fs-data.sh` chcon's the module's own `vendor/` tree on every boot, which is
what `apply.sh` always did for manual installs. See
[../mtk-power-setmode](../mtk-power-setmode/README.md) for the full incident -
there the same label cost the power HAL its library and bootlooped the device.

## Install

Option A, KernelSU Manager: flash
`../release/shark8_libpowerhal_noise_v1.0.zip`, then reboot.

Option B, in place on a rooted device:

    sh libpowerhal-noise/apply.sh
    adb reboot

`/vendor` is never written: the patched library is a KernelSU overlay, so it is
live only after the reboot.

## Verify

After the reboot, the overlay must be mounted and the file must be the patched
one (stock is `eb618de9c44807d6ec1b21eb47ee5eb0`, 275352 bytes):

    adb shell md5sum /vendor/lib64/libpowerhal.so

Proof method: lift the `libPowerHal` tag so that nothing is hidden by the level
filter, then fire the trigger directly. `powercli` comes from the separate
shark8-gamemode-gsi project.

    adb shell setprop persist.log.tag.libPowerHal V
    adb shell setprop ctl.restart power-hal-1-0
    adb shell powercli notify <pack> <act> <pid> 1 <uid>
    adb shell logcat -d

Healthy: `I libPowerHal: [perfNotifyAppState] pack:...` still present (the
function ran and the whitelist scan happened), `[PE] ... update cmd` lines still
present (the profile was applied), and **0** `ta_fg_pid`, **0** `gx_top_app_pid`,
**0** `Could not open`, **0** `E libPowerHal`.

Restore the tag afterwards:

    adb shell setprop persist.log.tag.libPowerHal E

## Revert

    sh libpowerhal-noise/revert.sh
    adb reboot

or remove `libpowerhal_noise` in the KernelSU Manager and reboot.

## Rebuilding the payload

    adb pull /vendor/lib64/libpowerhal.so stock-libpowerhal.so
    powershell -File libpowerhal-noise\patch_libpowerhal.ps1 -In stock-libpowerhal.so -Out patched-libpowerhal.so

The script fails loudly if the input is not the expected stock build (it checks
the stock md5/size, every literal it touches, and for the nop patches the decoded
`bl` target), so a vendor update cannot be patched by accident.

## Verified on device (2026-09-21, v5.1 / v5.2, pre-split)

### (b) missing foreground-pid nodes (v5.1)

- (b) (fg-pid nodes) verified after a reboot: `/vendor/lib64/libpowerhal.so`
  md5 = `177293a06360341c478ce6c8886bcc5e` (overlay mounted).
- Proof method: the `libPowerHal` tag was first lifted to `V`
  (`setprop persist.log.tag.libPowerHal V` + `setprop ctl.restart power-hal-1-0`)
  so that nothing is hidden by the level filter, then the trigger was fired
  directly - `powercli notify com.kurogame.wutheringwaves.global Common <pid> 1 <uid>`
  - and the whole buffer dumped.
- With the tag at `V`, the same notify that used to log the 4 ERROR lines now
  shows: `I libPowerHal: [perfNotifyAppState] pack:com.kurogame.wutheringwaves.global,
  act:Common, state:1, pid:..., uid:..., fps:-1` plus
  `multi_resumed_app_count: 1` / `multi_resumed_app_info[0] ...` (so the function
  ran and the whitelist scan happened), 15 `[PE] ... update cmd` lines (profile
  applied), and **0** `ta_fg_pid`, **0** `gx_top_app_pid`, **0** `Could not open`,
  **0** `E libPowerHal`.
- Before the patch the identical trigger produced exactly those 4 lines
  (2 paths x `Could not open` + `error : 2`).
- Tag restored to `E` afterwards: notify again -> 0 `E libPowerHal`,
  0 `Could not open`, 0 `update.cmd` (hidden by the level).
- Byte diff against the v5 patched library is limited to the two literals
  (0x12288..0x122A4, 0x122A7..0x122A9, 0x122AB..0x122CE; the leading `/` of both
  paths is unchanged), i.e. no code byte moved.
- Note: `/data/vendor/powerhal/power_app_cfg.xml` (the game's whitelist entry,
  owned by the shark8-gamemode-gsi project) survived the reboot, and the boot-time
  watcher still starts (`watch start pid=1649 packages=41`).

### (c) netdagent error block (v5.2)

- (c) (netdagent block) + `libPowerHal-bt` tag, verified after a reboot:
  `/vendor/lib64/libpowerhal.so` md5 = `58bd610b542ba4ca0747718d1189312a`
  (overlay mounted).
- Trigger: the only profile on this device that carries `PERF_RES_NET_*` is the
  stock sgame entry, so the notify was fired with it -
  `powercli notify com.tencent.tmgp.sgame 1 <focuslog pid> 1 10123`, then `0` for
  release - while no such app is installed (the profile lookup does not need it).
- With the tag at `V` (nothing hidden by the level filter): 93 buffered lines,
  **14** `perfNotifyAppState` lines (function ran), **27** `update cmd` lines
  (profile applied), and **0** `dispatchNetdagentCmd`, **0** `SetPriorityWithUID`,
  **0** `ClearPriorityWithUID`, **0** `empty slot`, **0** `sprintf fail`. The one
  surviving `NetdAgentCmd` line is the DEBUG
  `[NetdAgentCmd] netdagent firewall priority_set_uid 10123`, below the tag level.
- With the tag at `E` (the shipped state): **0** `libPowerHal` lines total for the
  same trigger. Before v5.2 the identical trigger produced
  `[NetdAgentCmd] dispatchNetdagentCmd failed` +
  `[netd_set_priority_uid] SetPriorityWithUID fail`.
- `libPowerHal-bt`: tag at `E` -> **0** BT lines; tag at `V` -> the 3 INFO lines
  come back, which proves the tag (and its hyphen) is the right knob.
- Still present on that trigger at the time, from `/vendor/bin/netdagent` (a
  real iptables failure, now a separate module): 2x `E NetdagentIptables: exec()
  res=0, status=256` + `E NetdagentService: run command firewall failed`. 0 avc
  denials in the same window.
- Byte diff against the v5.1 patched library: exactly 8 words
  (0x32FC8, 0x333C0, 0x33428, 0x33538, 0x33EB4, 0x33F98, 0x340B8, 0x341D8),
  each `bl __android_log_print` -> `nop`, 32 bytes total.

### (a) getCPUFreq log call (v5)

- (a) patch verified: `/vendor/lib64/libpowerhal.so` md5 =
  `fc650d79...` after reboot, and 4 screen off/on toggles produced **0**
  `getCPUFreq` lines, 0 `libPowerHal`, 0 `mtkpower_client`, 0 `avc:`. Same
  trigger on the unpatched boot logged exactly 1 `[getCPUFreq] error cid:2,
  nClusterNum:2` per toggle, so the delta is attributable to the patch.
- Only one process maps `libpowerhal.so`: the 64-bit
  `/vendor/bin/hw/vendor.mediatek.hardware.mtkpower@1.0-service`. The 32-bit
  `/vendor/lib/libpowerhal.so` has no consumer on this build, so it is left
  stock.
All of these measurements were taken when this content was section 7 of the
single combined `selinux_cosmetics` module, before the project was split into one
subdirectory per patch. The payload md5 shipped here
(`58bd610b542ba4ca0747718d1189312a`) is the same one verified in v5.3.

## Relationship to the other modules

The `persist.log.tag.libPowerHal` / `persist.log.tag.libPowerHal-bt` mute is a
different module, [`log-tag-mutes/`](../log-tag-mutes/README.md), and that tag
mute is what hides the remaining INFO volume of this library; this module keeps
the tag at `E` on purpose, so the real `E libPowerHal` diagnostics stay visible.
The daemon's own two ERROR lines are
[`netdagent-iptables/`](../netdagent-iptables/README.md).

## Ownership

This subdirectory is the only owner of `/vendor/lib64/libpowerhal.so` in the
project. Two KernelSU modules must never overlay the same file, so any further
binary silencing of this library belongs here. The 32-bit
`/vendor/lib/libpowerhal.so` is deliberately NOT patched: it has no consumer on
this build, and the only mapping process is the 64-bit
`/vendor/bin/hw/vendor.mediatek.hardware.mtkpower@1.0-service`.
