# shark8-gsi-logspam-cosmetics

Cosmetic patches for the Blackview Shark 8 running an Android 13/14 AOSP GSI
on the stock vendor image (KernelSU 0.9.4, kernel `5.10.223-rama982-gki-v1.19-ksu`).
Silences recurring sources of logspam caused by GSI/vendor mixing.
Zero functional change, zero permissive domains.

Since v4 it also carries the MTK power-stack fixes: three binary patches of vendor
libraries (`android.hardware.power-service-mediatek.so`, section 5;
`libpowerhal.so`, section 7; `lib_eara_io_scndet.so`, section 8) plus the eara_io
QoS log-tag mute (section 6), so one module covers the whole GSI/vendor logspam
surface. The standalone `shark8-mtkpower-setmode-spam` project is the origin of
the setMode patch and keeps the standalone variant + reverse-engineering notes.
v5.1 extends the `libpowerhal.so` patch to the two kernel nodes this build does
not have (section 7b): with it, a game start is down to zero `E libPowerHal`
lines on a normal (non-sgame-style) profile.
v5.2 closes the last two candidates: the whole netdagent error block inside
`libpowerhal.so` is nop'ed out (section 7c) and the `libPowerHal-bt` tag is
pinned to `E`. After v5.2 a profile with net-boost resources no longer produces a
single `E libPowerHal` line either.
v5.3 takes over `/vendor/bin/netdagent` itself (section 9): the daemon's own two
`NetdagentIptables` / `NetdagentService` ERROR lines - a genuine `iptables`
failure, not a log-level artifact - are nop'ed out, so the net-boost trigger is
finally silent end to end.

Ownership rule: this project is the single owner of every overlay under
`/vendor` on the MTK power stack (`android.hardware.power-service-mediatek.so`,
`libpowerhal.so`, `lib_eara_io_scndet.so`) and of the `persist.log.tag.*`
levels. Two KernelSU modules must never patch the same file, so any further
binary silencing of this stack belongs here, not in a new project. Candidates
already identified:

Remaining candidates (not patched yet):

* the `udp_socket` avc denial of the netdagent domain (seen once, permissive=0);
  adding an allow rule cannot fix the dispatch because the daemon's socket is
  not created at all (`socket netdagent` is commented out in
  `/vendor/etc/init/netdagent.rc`).

`/vendor/bin/netdagent` itself was the other entry here (`E NetdagentIptables:
exec() res=0, status=256`, `E NetdagentService: run command firewall failed`,
3 lines per net-boost notify). It is patched since v5.3 - this project owns that
overlay too, see section 9.

The two absent foreground-pid nodes that headed this list
(`/proc/driver/thermal/ta_fg_pid`, `/sys/module/ged/parameters/gx_top_app_pid`,
4 `E libPowerHal` lines per game start) are fixed in v5.1 - section 7.

The trigger itself (nothing to do with logs) lives in the separate
[shark8-gamemode-gsi](../shark8-gamemode-gsi) project: it feeds
`IMtkPower::notifyAppState` the foreground app/activity the GSI framework no
longer sends, so the stock vendor game profiles apply.

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

### 2. SELinux avc find denials on nonexistent hwservices

`system_app` (telephony) probes vendor radio hwservices this chipset does not
provide (samsung_slsi/sprd/huawei/qti interfaces) and the fingerprint HAL
probes oppo/oplus hwservices; every miss lands on the
`default_android_hwservice` fallback context and floods auditd with
`{ find }` denials. Allowed via the classic-format rules in `sepolicy.rule`:

    allow system_app default_android_hwservice hwservice_manager find
    allow system_app default_android_service service_manager find
    allow radio default_android_hwservice hwservice_manager find
    allow radio default_android_service service_manager find

### 3. Bonus: periodic process-getattr audit spam

The same mixing also makes `system_server`/`surfaceflinger`/`vold` audit
`getattr` on foreign domains (radio, gmscore_app, platform_app, priv_app,
untrusted_app, bluetooth, system_app, mediaprovider, su, ...) every few
seconds, plus a `zygote_tmpfs` write from `CachedAppOptimizer`. Same
allow-rule treatment, in classic (space-separated) format so that old and
new KernelSU both parse them.

### 4. events-buffer audit flood (notification LED daemon feed)

The on-device notification daemon streams the `log_id_events` buffer, which
was ~98% `auditd` `avc: denied` noise (12k+ lines in a ~3.3h ring). Root
cause: legitimate kernel-level checks on a GSI/vendor mix that lost their
allow rules, not broken services. Allowed (fix, not masking):

- `system_server` probing `system_suspend` wakelock state -> `process getattr`
  (~1/s, THE big one, ~12300/ring)
- `system_suspend` reading battery rails -> `sysfs`/`sysfs_batteryinfo` `dir read`
- `system_server` binder getattr on `keystore`/`rkpdapp`/`flipendo`/
  `isolated_app`/`shell`/`storaged`
- `priv_app` -> `gmscore_app` `file read` + `dir search` (the dir one is priv_app
  walking `/proc/<gmscore pid>`), `surfaceflinger` -> `gmscore_app`
  `process getattr`
- `gmscore_app` reading `adbd_prop`/`system_adbd_prop` (adb-over-wifi polling);
  the tmpfs prop files need `open` as well as `read`
- `adbroot`/`adbd` self-capability pairs while rooted adb is up
  (`sys_ptrace`, `dac_override`, `dac_read_search`)
- `mnld` reading `default_prop` (`file open` + `file read` on the tmpfs prop
  files; boot-time `{ open }` denial needs `open`, read alone covers nothing)

Verified: after apply, `logcat -b events` shows zero `avc: denied` in live
streaming; only real events (`dvm_lock_sample`, etc.) remain.

### 5. mtkpower@impl [setMode] spam (binary patch, vendor overlay)

Every ~1 s, forever, even on an idle desktop:

    E mtkpower@impl: [setMode] unknown type
    I mtkpower@impl: [setMode] type:6, enabled:0

`surfaceflinger` (GSI) toggles `Mode::EXPENSIVE_RENDERING` (AIDL value **6**)
once per second; the vendor HAL implements a different, older `Mode` layout, so
mode 6 hits its `default:` arm and logs `unknown type`. Behaviorally nothing
happens either way - mode 6 was already a no-op.

Fixed by patching the vendor library itself:
`module/vendor/lib64/android.hardware.power-service-mediatek.so` (19 KB overlay,
`/vendor` untouched, dm-verity happy). Stock md5 `40aea46435089ab1e2fc002d67f8ec2d`
-> patched md5 `a52fb102917c13c0b15ed83a13598394`.

| file offset | stock | patched | effect |
|-------------|-------|---------|--------|
| 0x31F0 | `0x94000288` `bl __android_log_print` | `0xD503201F` `nop` | drops the entry `[setMode] type:N, enabled:N` INFO line for every mode |
| 0x31FC | `0x54000928` `b.hi 0x3320` | `0x54000BA8` `b.hi 0x3370` | out-of-range modes return `AStatus_newOk` silently |
| 0x1852 | `0x42` | `0x56` | jump table: mode 4 (VR) -> silent OK |
| 0x1854 | `0x42` | `0x56` | jump table: mode 6 (EXPENSIVE_RENDERING) -> silent OK |

Modes 2/3/5/7 keep their original code paths; only the shared INFO log line is
dropped. `scripts/patch_powerhal.ps1` rebuilds the patched library from the
stock one and validates every byte it touches.

### 6. eara_io_service perf_lock_acq spam (log tags)

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
handled with a binary patch instead (section 8).

Correction (2026-09-21): the earlier claim that `@` is illegal in an Android
property name is wrong. The stock image itself ships
`persist.log.tag.mtkpower@impl=I`, and `setprop persist.log.tag.mtkpower@impl V`
+ `setprop ctl.restart power-hal-1-0` really does lift that tag to DEBUG on this
device. `persist.log.tag.eara_io@boost=E` / `...eval=E` would very likely work
too, but that has not been re-tested against the stock `lib_eara_io_scndet.so`,
so the verified binary patch stays.

### 7. libPowerHal: [getCPUFreq], the absent foreground-pid nodes, the netdagent block (binary patch)

**(a) cluster 2 error**

    E libPowerHal: [getCPUFreq] error cid:2, nClusterNum:2

~10 lines per game load and once per screen off/on. `getCPUFreq(int cid, int opp)`
returns -1 when `cid < 0 || cid >= nClusterNum`, and something on this 2-cluster
MT6789 still asks for cluster 2 (a leftover entry from 3-cluster SoCs). The -1 is
the vendor's normal "skip this update" path - the request is a no-op - so only the
log call is dropped, the return value and every other error path stay.

**(b) missing kernel nodes (v5.1)**

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

Fix: repoint both `.rodata` path literals at `/dev/null`. `open()` succeeds, the
write is discarded, `set_value()` returns 0, the retry flag is set and nothing is
logged. No behavior change (the writes could never succeed), and unlike nop'ing
`set_value()`'s log calls this keeps the diagnostics of every other node write
intact. Both literals are referenced exactly once in the whole library (checked
with `llvm-objdump -d`), so nothing else is affected. Cost: if a future kernel
does grow these nodes, the per-app hint stays off.

`module/vendor/lib64/libpowerhal.so` (275 KB overlay), stock md5
`eb618de9c44807d6ec1b21eb47ee5eb0` -> patched md5 `58bd610b542ba4ca0747718d1189312a`
(v5.1 md5 was `177293a06360341c478ce6c8886bcc5e`, v5 md5
`fc650d79c5eeaa247d3a4d5a34158bf2`).

| file offset | stock | patched | effect |
|-------------|-------|---------|--------|
| 0x281E0 | `0x94005BCC` `bl __android_log_print` | `0xD503201F` `nop` | drops the ERROR line; `0x281E4 b 0x28210` still returns -1 |
| 0x12287 | `/proc/driver/thermal/ta_fg_pid` | `/dev/null` (NUL-padded) | thermal fg-pid write becomes a successful no-op, no ERROR line |
| 0x122A6 | `/sys/module/ged/parameters/gx_top_app_pid` | `/dev/null` (NUL-padded) | GED top-app-pid write becomes a successful no-op, no ERROR line |

This is a separate library from section 5, so the tag stays at `E` and real
`libPowerHal` errors keep printing. `scripts/patch_libpowerhal.ps1` rebuilds it
and validates the fmt string, three surrounding instructions, both path literals
and their NUL terminators before touching anything.

**(c) netdagent error block (v5.2)**

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

The daemon's own two lines (`E NetdagentIptables: exec() res=0, status=256` and
`E NetdagentService: run command firewall failed`) come from a different file,
`/vendor/bin/netdagent` - silenced since v5.3, section 9.

### 8. eara_io@boost / eara_io@eval INFO firehose (binary patch)

The remaining ~120 lines per game load come from `lib_eara_io_scndet.so`
(scene detector inside `/vendor/bin/eara_io_service`). The original reason for
patching instead of using `persist.log.tag.*` was wrong (see the correction
above: `@` is legal in property names), but the patch is what is verified on
device, so it stays until the tag route is re-tested. The spam itself:

    I eara_io@boost: [eara_io_boost] eara_io_boost 2 , ta 80
    I eara_io@eval:  [eara_io_eval] r2 462 , r 528 , w2 0 , w 0 , w+r 528 , w2+r2 462 , w3+r3 1628

`module/vendor/lib64/lib_eara_io_scndet.so` (19 KB overlay), stock md5
`54218e4a8c26e09645c5d35f622ad4fd` -> patched md5
`71af817be84f670a088ce439db96e18c`.

| file offset | stock | patched | effect |
|-------------|-------|---------|--------|
| 0x358C | `0x940000A9` `bl __android_log_print` | `0xD503201F` `nop` | drops `eara_io_boost 0 , ta 0` (level-0 / reset path, the bulk of the flood) |
| 0x3688 | `0x9400006A` `bl __android_log_print` | `0xD503201F` `nop` | drops `eara_io_boost %d , ta %d` (levels 1..4) |
| 0x2CF8 | `0x940002CE` `bl __android_log_print` | `0xD503201F` `nop` | drops `[eara_io_eval] r2 %d , ...` |

Only the three INFO calls are dropped: every state update before them stays, and
the ERROR paths of the same functions (`[%s] no data found`, `perfLockAcq error`,
`dlopen fail`, `notify: acq perf_hdl`) keep logging. `scripts/patch_libeara.ps1`
validates both format strings, both tag strings and four context instructions
before patching.

Reproducing the spam without a game is possible with `tools/eara_boost_probe.c`:
it dlopens the library and calls its exported `eara_io_boost(int)`, which is
exactly what the scene detector calls.

    D:\System\Apps\android-sdk\...\clang --target=aarch64-linux-android21 ^
        --sysroot=<ndk>\toolchains\llvm\prebuilt\windows-x86_64\sysroot ^
        -fPIE -pie -O2 -o eara_boost_probe tools\eara_boost_probe.c
    adb push eara_boost_probe /data/local/tmp/ && adb shell chmod 755 /data/local/tmp/eara_boost_probe
    adb shell 'logcat -c; /data/local/tmp/eara_boost_probe 3; logcat -d | grep eara_io@'

Caveat: the probe runs in the `su` domain, so its perf lock additionally produces
`E libPowerHal: Could not open '/proc/<pid>/comm'` plus a handful of
`mtk_hal_power -> su` proc denials. That is a probe artifact - a real app
requests locks from `untrusted_app`/`priv_app`, which are already readable.

### 9. /vendor/bin/netdagent: the daemon's own iptables ERROR lines (binary patch, v5.3)

The last lines the net-boost trigger produced after v5.2 did not come from any
library but from the vendor daemon that `libpowerhal.so` talks to:

    E NetdagentIptables: exec() res=0, status=256
    E NetdagentService: run command firewall failed

The daemon runs each `firewall` command with `/system/bin/iptables-wrapper-1.0`;
the exec succeeds (`res=0`) and the wrapper exits 1 (`status=256` is waitpid's
raw value for exit code 1), so `run_command()` logs the failure and the caller
logs it again. There is no AVC denial and no further diagnostic in that path,
only these two lines - a real functional failure of this GSI/vendor mix, not a
log-level artifact, and `E` cannot be muted by a tag (v5.2 verdict). Hiding them
makes the log clean; it does not make the net hints work (see the remaining
`udp_socket` candidate above).

`module/vendor/bin/netdagent`, stock md5 `6e3f6b430386eb032715038bf7544120`
(55616 bytes) -> patched md5 `f58dbc8877c401ed4d2bcf9d0436bb42`.

| file offset | stock | patched | message dropped |
|-------------|-------|---------|-----------------|
| 0x56E0 | `0x940017D0` `bl __android_log_print` | `0xD503201F` `nop` | `run command %s failed`, tag `NetdagentService` (0x2F5D), fmt 0x2AAF |
| 0xB0BC | `0x94000159` `bl __android_log_print` | `0xD503201F` `nop` | `exec() res=%d, status=%d`, tag `NetdagentIptables` (0x3639), fmt 0x24BC |

Both sites fall through to instructions that define nothing the log call could
have defined (`mov w22, #-1` and `ldrb w8, [sp, #0x18]`), so only the print is
lost; the iptables call, its status and the return values stay. Each format
string is referenced exactly once in the whole binary (checked with
`llvm-objdump -d`). `scripts/patch_netdagent.ps1` re-checks the stock md5 and
size, the four literals, both expected `bl` words and - via imm26 decode - that
each call targets `__android_log_print@plt` (0xB620).

SELinux: the module file keeps `u:object_r:netdagent_exec:s0` (the init service
enters via that type, `/(vendor|system/vendor)/bin/netdagent` in
`vendor_file_contexts`), so `apply.sh` re-labels it after the generic
`chcon -R vendor_file` over `vendor/`.


## Layout

    module/
      module.prop       KernelSU module metadata
      sepolicy.rule     SELinux allow-rules, classic format (space-separated)
      post-fs-data.sh   re-applies rules at boot, flushes AVC cache, sets log tags
      vendor/lib64/android.hardware.power-service-mediatek.so
                        patched MTK power HAL (setMode logspam fix)
      vendor/lib64/libpowerhal.so
                        patched MTK powerhal (getCPUFreq error log fix + absent
                        fg-pid nodes repointed at /dev/null + netdagent error
                        block nop'ed)
      vendor/lib64/lib_eara_io_scndet.so
                        patched eara_io scene detector (INFO firehose fix)
      vendor/bin/netdagent
                        patched netdagent daemon (own iptables ERROR lines
                        nop'ed; keeps u:object_r:netdagent_exec:s0)
    scripts/
      apply.sh          device-side: copy module + apply rules now + persist log tags
      revert.sh         device-side: remove module + reset log tags
      patch_powerhal.ps1
                        host-side: rebuild the patched power HAL service .so
      patch_libpowerhal.ps1
                        host-side: rebuild the patched libpowerhal.so
      patch_libeara.ps1
                        host-side: rebuild the patched lib_eara_io_scndet.so
      patch_netdagent.ps1
                        host-side: rebuild the patched netdagent daemon
    tools/
      eara_boost_probe.c
                        device-side trigger for the eara_io INFO logs (verification)
    release/shark8_gsi_logspam_cosmetics_v5.3.zip
                        ready-to-flash KernelSU module zip

## Why classic (space-separated) sepolicy.rule syntax

KernelSU 0.9.4's `ksud` parser does not understand the magisk colon form
`allow src target:class perm` (it fails with `Failed to parse policy
statement`), it only accepts `allow src target class perm`. Newer KernelSU
(v1.0.0+) supports both, so shipping classic syntax keeps the module working
across versions. Additionally 0.9.4 has no `reset_avc_cache()`: once a denial
has been cached, it keeps firing even after the rule is applied, so the
`post-fs-data.sh` script toggles enforcing off/on to flush the cache.

## Install

Option A, KernelSU Manager: install/update with
`release/shark8_gsi_logspam_cosmetics_v5.3.zip` (md5
`a94e132904107f5cd3b26a8e00442149`), then reboot.
`post-fs-data.sh` applies the rules and the log tags at boot, and the vendor
overlay mounts on reboot.

Option B, in-place push on a rooted device (`adb root`):

    sh scripts/apply.sh

This copies the module files (including the patched power HAL and the patched netdagent daemon) into
`/data/adb/modules/selinux_cosmetics`, applies the sepolicy rules immediately,
flushes the AVC cache, and persists the four log-tag props. The sepolicy and
log-tag parts are live immediately; the patched vendor files need a reboot.

    adb reboot

## Revert

In the KernelSU Manager remove the `selinux_cosmetics` module and reboot, or:

    sh scripts/revert.sh   # removes module + resets all four log tags

Individual tags can be re-enabled at any time (no reboot needed):

    setprop persist.log.tag.ImsProvisioningController ""
    setprop persist.log.tag.libPowerHal I
    setprop persist.log.tag.libPowerHal-bt I
    setprop persist.log.tag.mtkpower_client I

## Rebuilding the patched vendor binaries and libraries

    adb pull /vendor/lib64/android.hardware.power-service-mediatek.so stock.so
    powershell -File scripts\patch_powerhal.ps1 -In stock.so -Out patched.so

    adb pull /vendor/lib64/libpowerhal.so stock-libpowerhal.so
    powershell -File scripts\patch_libpowerhal.ps1 -In stock-libpowerhal.so -Out patched-libpowerhal.so

    adb pull /vendor/lib64/lib_eara_io_scndet.so stock-scndet.so
    powershell -File scripts\patch_libeara.ps1 -In stock-scndet.so -Out patched-scndet.so

    adb pull /vendor/bin/netdagent stock-netdagent
    powershell -File scripts\patch_netdagent.ps1 -In stock-netdagent -Out patched-netdagent

All four scripts fail loudly if the input is not the expected stock build (each
checks the stock md5/size, every literal it touches, and for the two nop patches
the decoded l target), so a vendor update cannot be patched by accident.

## Verified on device (2026-09-21, v5.3)

- Section 9 (netdagent daemon) verified after a reboot:
  `/vendor/bin/netdagent` md5 = `f58dbc8877c401ed4d2bcf9d0436bb42` (overlay
  mounted), label `u:object_r:netdagent_exec:s0`, `pidof netdagent` = 1590,
  `init.svc.netdagent` = `running` - the overlay does not break the init service.
  `/vendor/lib64/libpowerhal.so` stayed at `58bd610b542ba4ca0747718d1189312a`.
- Same trigger as below (`powercli notify com.tencent.tmgp.sgame 1 <focuslog pid>
  1 10123`, tag at `V`, power HAL restarted): **0** `Netdagent` lines in the whole
  buffer, where v5.2 produced 2x `NetdagentIptables: exec() res=0, status=256` +
  `NetdagentService: run command firewall failed`. Still **0**
  `dispatchNetdagentCmd`, `SetPriorityWithUID`, `empty slot`, `sprintf fail`; the
  one surviving `NetdAgentCmd` line is the DEBUG
  `[NetdAgentCmd] netdagent firewall priority_set_uid 10123`, below the tag level.
  Proof that the path still runs: 8 `perfNotifyAppState` and 27 `update cmd` lines.
- Byte diff against the stock daemon: exactly 2 words (0x56E0, 0xB0BC), each
  `bl __android_log_print` -> `nop`.
## Verified on device (2026-09-21, v5.2)

- Section 7c (netdagent block) + `libPowerHal-bt` tag, verified after a reboot:
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
  real iptables failure, section 7c): 2x `E NetdagentIptables: exec() res=0,
  status=256` + `E NetdagentService: run command firewall failed`. Patched in
  v5.3, section 9. 0 avc denials in the same window.
- Byte diff against the v5.1 patched library: exactly 8 words
  (0x32FC8, 0x333C0, 0x33428, 0x33538, 0x33EB4, 0x33F98, 0x340B8, 0x341D8),
  each `bl __android_log_print` -> `nop`, 32 bytes total.

## Verified on device (2026-09-21, v5.1)

- Section 7b (fg-pid nodes) verified after a reboot: `/vendor/lib64/libpowerhal.so`
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

## Verified on device (2026-09-21, v5)

- Merged module `selinux_cosmetics` v5 = v3 rules + three vendor overlays +
  tag mutes.
- Full reboot verification: `/vendor/lib64/android.hardware.power-service-mediatek.so`
  md5 = `a52fb102...` (overlay mounted), all three tags persisted as `E`, crash
  buffer empty.
- 40 s idle + screen off/on: `libPowerHal` 0 lines, `mtkpower_client` 0 lines,
  `setMode` 2 lines (the legitimate `[setMode] Disable All` / `Restore All` from
  the mode 7 handler, once per screen toggle).
- Mute proof: same screen-toggle trigger with tags at `I` -> 24 `libPowerHal`
  lines, with `E` -> 0.
- First boot window exposed three uncovered denials (`priv_app -> gmscore_app
  dir search`, `gmscore_app -> adbd_prop`/`system_adbd_prop file open`); rules
  added, all 69 rules now parse+apply cleanly, and the next 60 s window shows
  **0** `avc:` lines (after the usual enforce toggle to flush the stale deny
  cache).
- The standalone `mtkpower_setmode_logfix` module was removed from the device;
  both halves now live here.
- Section 7 patch verified: `/vendor/lib64/libpowerhal.so` md5 =
  `fc650d79...` after reboot, and 4 screen off/on toggles produced **0**
  `getCPUFreq` lines, 0 `libPowerHal`, 0 `mtkpower_client`, 0 `avc:`. Same
  trigger on the unpatched boot logged exactly 1 `[getCPUFreq] error cid:2,
  nClusterNum:2` per toggle, so the delta is attributable to the patch.
- Only one process maps `libpowerhal.so`: the 64-bit
  `/vendor/bin/hw/vendor.mediatek.hardware.mtkpower@1.0-service`. The 32-bit
  `/vendor/lib/libpowerhal.so` has no consumer on this build, so it is left
  stock.
- Remaining known residue: nothing that recurs on a normal boot - the three
  vendor overlays plus the two tag mutes now cover every recurring source found
  so far.
- Section 8 patch verified with `tools/eara_boost_probe` (calls the exported
  `eara_io_boost(int)` directly, which is what the scene detector does):
  unpatched library -> 4 probe calls produced 4 `eara_io@boost` lines
  (`1 , ta 70`, `2 , ta 80`, `3 , ta 80`, `0 , ta 0`); after the patch and a
  reboot -> same 4 calls, **0** `eara_io@boost`, 0 `eara_io@eval`, 0
  `eara_io@idxcollector`.
- One new denial showed up while testing and is now allowed:
  `priv_app -> gmscore_app file open` (`/proc/<gmscore>/attr/current`, the same
  walk that already needed `dir search` + `file read`). All 70 rules parse and
  apply cleanly via `ksud sepolicy apply`, and a 60 s window afterwards shows
  **0** `avc:`, 0 `libPowerHal`, 0 `mtkpower_client`, 0 `setMode`.
- Adding a file to an existing module directory does not show up in `/vendor`
  until reboot (KernelSU mounts the overlay paths it saw at boot) - new
  overlays need one reboot.

## Verified on device (2026-09-15, v3)

- Module `selinux_cosmetics` v3 (adds `mnld -> default_prop file open`).
- Full reboot verification: **0** `mnld` denials across boot + live window
  (before: an `{ open }` denial from `mnld` on `default_prop` at boot).
- Post-boot live: no recurring `avc: denied` (75s window after boot, 5
  one-shot lines total, 4 being the intentional rooted-adb `adbroot`/`adbd`
  capability pair, 1 rare `webview_zygote -> zygote_tmpfs file map`).
- Boot-time once-per-boot vendor one-offs (zygote `vendor_default_prop`,
  `mtk_hal_camera` `default_prop`, `nvram_daemon`/`fuelgauged_nvram`
  `sysfs_dt_firmware_android`, `init_insmod_sh` `sys_nice`) are out of scope
  for this module (single-shot, not spam).
- Earlier run (2026-09-04): `find` denials from fingerprint/radio HALs and
  `getattr` bursts fixed; residual one-off `adbroot`/`adbd` capability pair
  when lifting `adb root` is intentional, not logspam.
