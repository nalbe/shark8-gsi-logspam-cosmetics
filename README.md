# shark8-gsi-logspam-cosmetics

Mostly cosmetic patches for the Blackview Shark 8 running an Android 13/14 AOSP
GSI on the stock vendor image (KernelSU 0.9.4, kernel
`5.10.223-rama982-gki-v1.19-ksu`). Silences recurring sources of logspam caused
by GSI/vendor mixing, and fixes the two things that were real battery problems
because they kept the device from ever reaching suspend: the alarmtimer
suspend-abort storm and the `wlan0` IRQ. No permissive domains, and no
functional change outside those two.

Every patch in this project is one directory, one KernelSU module, one
README, one flashable zip. Nothing is shared between them except this index.

## The modules

| directory | module id | silences | payload |
|---|---|---|---|
| [`selinux-avc-rules/`](selinux-avc-rules) | `selinux_avc_rules` | `avc: denied` audit spam: hwservice `find` probes, periodic `getattr`, the `log_id_events` flood (68 allow rules) | `sepolicy.rule` + `post-fs-data.sh` |
| [`log-tag-mutes/`](log-tag-mutes) | `log_tag_mutes` | `ImsProvisioningController` W every 30 s, `eara_io_service` perf_lock_acq flood (~650 lines per game load) | 4 `persist.log.tag.*` props |
| [`mtk-power-setmode/`](mtk-power-setmode) | `mtk_power_setmode` | `mtkpower@impl: [setMode] unknown type` / `type:6, enabled:0`, once per second, forever | overlay of `android.hardware.power-service-mediatek.so` |
| [`libpowerhal-noise/`](libpowerhal-noise) | `libpowerhal_noise` | `[getCPUFreq] error cid:2`, the two absent foreground-pid nodes, the netdagent error block (8 calls) | overlay of `libpowerhal.so` |
| [`eara-io-scene-detector/`](eara-io-scene-detector) | `eara_io_scene_detector` | `eara_io@boost` / `eara_io@eval` INFO firehose (~120 lines per game load) | overlay of `lib_eara_io_scndet.so` |
| [`netdagent-iptables/`](netdagent-iptables) | `netdagent_iptables` | the netdagent daemon's own `exec() res=0, status=256` / `run command firewall failed` ERROR pair | overlay of `netdagent` |
| [`alarmtimer-freezer/`](alarmtimer-freezer) | `alarmtimer_freezer_off` | the `alarmtimer.1.auto ... error -16` suspend-abort storm - **not cosmetic**, see below | DeviceConfig `use_freezer=false` |
| [`wlan-loglevel/`](wlan-loglevel) | `wlan_loglevel` | the `[wlan]` conninfra firehose, 6-8 lines/s while any WiFi traffic moves (`kalPerMonUpdate`, `kalDumpHifStats`, `halSetFWOwn`, `halSetDriverOwn`, `cnmTimer*`) - **not cosmetic**, the `wlan0` IRQ ran at ~41/s | `/proc/net/wlan/dbgLevel` `0x2f` -> `0x03` on all 32 modules + `autoPerfCfg ForceEnable:0` |
| [`charger-loglevel/`](charger-loglevel) | `charger_loglevel` | what the MTK charger driver prints through its own knob - **no measured win**, see below | `charger_log_level` = 0 |
| [`gauge-loglevel/`](gauge-loglevel) | `gauge_loglevel` | what the MT6358 fuel gauge driver prints through its own knob - **no measured win**, see below | `FG_daemon_log_level` = 0 |

Each row links to that patch's README, which has the full analysis: the log
lines, the root cause, the byte-level patch, the install/verify/revert commands
and the on-device evidence.

`alarmtimer_freezer_off` and `wlan_loglevel` are the two that are not cosmetic.
On this device the storm the first one fixes was a real battery problem - every
s2idle attempt was aborted, so the phone never slept. The second one keeps the
`wlan0` IRQ at ~41/s, which has the same effect for the same reason: the device
never reaches a quiet suspend. They ship separately from the rest for exactly
that reason: each changes a subsystem setting instead of silencing a log, and
you may well want to be able to pull one without touching the log patches.

`charger_loglevel` and `gauge_loglevel` are the opposite case, and their READMEs
say so plainly: they are real driver knobs set to 0, but they do **not** stop
`sgm4154x_dump_register` (the ~4 lines/s SGM4154x register dump), because that
function belongs to the charger driver and both `sgm415xx` and `mt6358_battery`
are built into vmlinux - there is no `.ko` to patch, only a vmlinux patch, which
is not done. They cost nothing and may still catch driver chatter nobody has
counted yet, but do not expect a measurable dmesg drop from them.

## Ownership rule

**No two KernelSU modules may touch the same file.** Concretely, in this
project:

- `selinux-avc-rules` owns `sepolicy.rule` and the only `/sys/fs/selinux/enforce`
  toggle.
- `log-tag-mutes` owns every `persist.log.tag.*` prop this project sets.
- Each of the four binary-patch directories owns exactly one file under
  `/vendor`, and `/vendor` is never written to - the patched file is a KernelSU
  overlay (dm-verity stays happy, `rm` of the module restores the stock file).
- `alarmtimer-freezer` owns `activity_manager_native_boot use_freezer`.
- `wlan-loglevel` owns `/proc/net/wlan/dbgLevel` and `/proc/net/wlan/autoPerfCfg`.
- `charger-loglevel` owns `charger_log_level`, `gauge-loglevel` owns
  `FG_daemon_log_level`. Both are driver module parameters, i.e. runtime-only
  values: they are back at the driver default after every reboot, which is why
  each has a `post-fs-data.sh` and no `service.sh`.

Anything further that silences this MTK power stack - a tag, a rule, or a byte
in one of those four vendor files - belongs in the directory that already owns
it, not in a new one. That is the whole reason the project is split this way:
adding a patch means adding a rule to an existing owner, not a new module
fighting over the same overlay path.

## Shared conventions

**`/vendor` is never written.** All four binary patches ship as KernelSU
overlays, so the stock vendor partition stays untouched and removing the module
+ reboot restores the stock file. The payloads are byte-identical to the ones
verified in the pre-split module `selinux_cosmetics` v5.3.

| file | stock md5 | patched md5 |
|---|---|---|
| `/vendor/lib64/android.hardware.power-service-mediatek.so` | `40aea46435089ab1e2fc002d67f8ec2d` | `a52fb102917c13c0b15ed83a13598394` |
| `/vendor/lib64/libpowerhal.so` | `eb618de9c44807d6ec1b21eb47ee5eb0` | `58bd610b542ba4ca0747718d1189312a` |
| `/vendor/lib64/lib_eara_io_scndet.so` | `54218e4a8c26e09645c5d35f622ad4fd` | `71af817be84f670a088ce439db96e18c` |
| `/vendor/bin/netdagent` | `6e3f6b430386eb032715038bf7544120` | `f58dbc8877c401ed4d2bcf9d0436bb42` |

**A tag level is the first tool, not the last.** Anything that is genuinely
INFO/W noise is muted with `persist.log.tag.*` (`log-tag-mutes`). Anything that
logs at `E` for a condition that cannot happen on this GSI/vendor mix is a
binary patch, because a level filter cannot reach it. `mtkpower@impl` and the
`eara_io@*` tags are the awkward middle: a tag route exists for them but was
never re-tested against the stock libraries, so the verified binary patch
stays. Each README says which case it is.

**Classic sepolicy syntax.** KernelSU 0.9.4's `ksud` parser does not
understand the magisk colon form `allow src target:class perm` (it fails with
`Failed to parse policy statement`), it only accepts
`allow src target class perm`. Newer KernelSU (v1.0.0+) supports both, so
`selinux-avc-rules` ships classic syntax to keep working across versions.
One perm per line, always: 0.9.4 also parses only the *first* perm of a line and
silently drops the rest, so `allow x y file read getattr open` becomes
`allow x y file read` with no error. Additionally 0.9.4 has no
`reset_avc_cache()`: once a denial has been cached it keeps firing even after
the rule is applied, so `post-fs-data.sh` toggles enforcing off/on to flush the
cache.

**An overlay payload must carry the stock SELinux label.** `ksud module install`
extracts zip payloads as `u:object_r:system_file:s0`, and KernelSU mounts the
`/vendor` overlay with `seclabel`, so the linker and init see the replacement
file with that label instead of the stock one. Vendor domains are only granted
the stock label, so they get denied on the very file they need:

    F/linker: CANNOT LINK EXECUTABLE "/vendor/bin/hw/vendor.mediatek.hardware.mtkpower@1.0-service":
              library "android.hardware.power-service-mediatek.so" not found
    avc:  denied  { read } for  name="android.hardware.power-service-mediatek.so" dev="overlay"
          scontext=u:r:mtk_hal_power:s0 tcontext=u:object_r:system_file:s0 tclass=file

That one bootlooped the device on 2026-09-26: init restarted the power HAL every
5 s, `android.hardware.power.IPower/default` never registered and
`sys.boot_completed` never reached 1. Each of the four overlay modules therefore
ships a `post-fs-data.sh` that chcon's its own `vendor/` tree at every boot -
`vendor_file` for the three libraries, and for `netdagent` `vendor_file` on the
directories plus `netdagent_exec` on the binary, because it is an init service
with its own exec type. `apply.sh` always did this for manual installs, which is
why the pre-split module never showed the problem: it was only ever installed by
hand. `selinux-avc-rules` additionally carries `allow mtk_hal_power system_file
file ...` as a fallback for the window before the relabel has run.

**Adding an overlay file needs a reboot.** KernelSU mounts the overlay paths it
saw at boot, so a file added to an existing module directory does not show up
in `/vendor` until the next boot.

**Module scripts and the vendor daemon need their exec bit in the zip.**
KernelSU silently skips a `post-fs-data.sh` or `service.sh` that lands as
`0644`, and .NET writes every archive as "made by MS-DOS", which makes readers
ignore the Unix mode in the external attributes. `build.ps1` therefore sets the
mode itself and then patches the version-made-by host byte of every central
directory entry to Unix: `0755` on `.sh` and on everything under `vendor/bin/`,
`0644` on the rest. The three `vendor/lib64` payloads are `dlopen`'d and only
have to be readable; `netdagent` is an init service, and at `0644` init cannot
exec it at all - the service crash-loops with `cannot execv('/vendor/bin/
netdagent') ... Permission denied`, status 127. Verify with any zip tool that
shows modes - `unzip -Z` on Linux, the entry properties on Windows.

## Install

Flash the zips you want in the KernelSU Manager, one per patch:

    release/shark8_selinux_avc_rules_v1.0.zip
    release/shark8_log_tag_mutes_v1.0.zip
    release/shark8_mtk_power_setmode_v1.0.zip
    release/shark8_libpowerhal_noise_v1.0.zip
    release/shark8_eara_io_scene_detector_v1.0.zip
    release/shark8_netdagent_iptables_v1.0.zip
    release/shark8_alarmtimer_freezer_off_v1.0.zip
    release/shark8_wlan_loglevel_v1.0.zip
    release/shark8_charger_loglevel_v1.0.zip
    release/shark8_gauge_loglevel_v1.0.zip

then reboot once. All ten together reproduce what the single
`selinux_cosmetics` v5.3 module did, plus the freezer fix, plus the three
modules split out of the old `shark8_quietlogs` module.

Or install in place on a rooted device, per patch:

    sh selinux-avc-rules/apply.sh
    sh log-tag-mutes/apply.sh
    sh mtk-power-setmode/apply.sh
    sh libpowerhal-noise/apply.sh
    sh eara-io-scene-detector/apply.sh
    sh netdagent-iptables/apply.sh
    sh alarmtimer-freezer/apply.sh
    sh wlan-loglevel/apply.sh
    sh charger-loglevel/apply.sh
    sh gauge-loglevel/apply.sh
    adb reboot

Each `apply.sh` prints the md5 of the payload it installed and the md5 it
wants, so a wrong payload is visible without touching the device.

Build the zips from the source tree with:

    powershell -File build.ps1

(one zip per module directory, flat layout, `module.prop` at the zip root.)

## Revert

Per patch, `sh <dir>/revert.sh`, then reboot where the module owned an overlay
or a boot script. In the KernelSU Manager, remove the module by id
(`selinux_avc_rules`, `log_tag_mutes`, `mtk_power_setmode`, `libpowerhal_noise`,
`eara_io_scene_detector`, `netdagent_iptables`, `alarmtimer_freezer_off`,
`wlan_loglevel`, `charger_loglevel`, `gauge_loglevel`).

Two things no revert can take back without a reboot, both documented in the
patch README:

- applied SELinux rules stay in the kernel policy until the reboot;
- `persist.log.tag.*` props are persistent and outlive the module, so
  `log-tag-mutes/revert.sh` resets them explicitly.

The `/proc` and sysfs knobs of `wlan_loglevel`, `charger_loglevel` and
`gauge_loglevel` need no live restore - they are runtime values that reset at
the next boot anyway. `wlan-loglevel/revert.sh` still writes the stock values
back (`0x2f`, `ForceEnable:1`) so you get the firehose again immediately;
the other two only remove the module, because their stock values were never
recorded (see their READMEs).

If the old combined module is still on the device, remove
`selinux_cosmetics` before installing the split ones - two modules must never
overlay the same vendor file. Likewise remove the old `shark8_quietlogs` before
installing `wlan_loglevel` / `charger_loglevel` / `gauge_loglevel`: it writes
the same `dbgLevel`, `charger_log_level` and `FG_daemon_log_level` nodes.

    adb shell su -c 'rm -rf /data/adb/modules/selinux_cosmetics'
    adb shell su -c 'rm -rf /data/adb/modules/shark8_quietlogs'

## Remaining candidates (not patched yet)

* the `udp_socket` avc denial of the netdagent domain (seen once, permissive=0);
  adding an allow rule cannot fix the dispatch because the daemon's socket is
  not created at all (`socket netdagent` is commented out in
  `/vendor/etc/init/netdagent.rc`). Consequence: the net-boost hints do not
  work, they only used to log. See
  [`netdagent-iptables/`](netdagent-iptables/README.md).
* `sgm4154x_dump_register` (~4 lines/s): the SGM4154x charger IC dumping
  registers `0x0..0xf` over I2C. Survives every log-level knob
  (`charger_log_level` 0 and 2, `battery/log_level`, `FG_daemon_log_level` all
  tested), and `sgm415xx` / `mt6358_battery` are built into vmlinux, so there
  is no `.ko` to patch - `grep -rls sgm4154x_dump_register` across all 181
  modules in `/vendor_dlkm` returns nothing. Only a vmlinux binary patch (NOP
  the printk) can stop it, which needs the kernel image out of `vendor_boot`
  and a matching vmlinux analysis. It is charge-state driven, so it also goes
  quiet off charge. See [`charger-loglevel/`](charger-loglevel/README.md).
* `[wdk-c]` per-CPU dumps from `aee_hangdet`: no module parameters, and
  **do not `rmmod aee_hangdet`** - it looks safe (`refcnt 0`, no
  `/sys/module/aee_hangdet/parameters`) but it reboots the phone, verified the
  hard way. No knob, no patch target. Left alone on purpose.
* `[WMT-CONSYS-HW][I]consys_dump_*` on every resume (`consys_dump_osc_state`,
  `consys_dump_gating_state`, `plat_resume_handler` with a full register dump).
  Found in the dmesg of the current boot, not yet analyzed.

The two absent foreground-pid nodes that used to head this list
(`/proc/driver/thermal/ta_fg_pid`, `/sys/module/ged/parameters/gx_top_app_pid`,
4 `E libPowerHal` lines per game start) are fixed in
[`libpowerhal-noise/`](libpowerhal-noise/README.md).

The trigger itself (nothing to do with logs) lives in the separate
[shark8-gamemode-gsi](../shark8-gamemode-gsi) project: it feeds
`IMtkPower::notifyAppState` the foreground app/activity the GSI framework no
longer sends, so the stock vendor game profiles apply.

## Rejected: the ART boot-image filter

`shark8-art-tune` set `dalvik.vm.image-dex2oat-filter=verify` to stop a
per-boot full-speed `dex2oat` pass over the boot classpath. It is **not** part
of this project, and the module was removed from the device, because the
property cannot do that on this ROM: AOSP makes the boot image compiler filter
`speed-profile` unconditionally since Android 12, and on this build ART never
looks at the property at all - `libartbase.so` references only
`dalvik.vm.boot-image` and `dalvik.vm.profilebootclasspath`. There was no
boot-time pass to suppress either: nothing dex2oat-related in any log buffer,
`/data/dalvik-cache` last written 2026-09-22, and no `boot.art` anywhere (not
in the ART APEX, not in `/system/framework`, not in `/data`). Only app
compilation is tunable on A12+ (`pm.dexopt.*`); the boot classpath is not, so
there is nothing to put in a module here.

## Layout

    selinux-avc-rules/     sepolicy rules + boot-time re-apply
    log-tag-mutes/         the four persist.log.tag.* mutes
    mtk-power-setmode/     setMode patch + patch_powerhal.ps1 + overlay
    libpowerhal-noise/     getCPUFreq/fg-pid/netd block patch + patch_libpowerhal.ps1 + overlay
    eara-io-scene-detector/  eara_io@boost/@eval patch + patch_libeara.ps1 + overlay
                           + tools/eara_boost_probe.c (device-side trigger, verification only)
    netdagent-iptables/    daemon patch + patch_netdagent.ps1 + overlay
    alarmtimer-freezer/    the freezer fix, own README
    wlan-loglevel/         dbgLevel 0x2f -> 0x03 on 32 modules + autoPerfCfg off
    charger-loglevel/      charger_log_level = 0
    gauge-loglevel/        FG_daemon_log_level = 0
    release/               flashable zips, one per module
    release/legacy/        the pre-split combined-module zips (v5.0 .. v5.3), kept for reference
    build.ps1              zip every module directory

## History of the pre-split module

Before the split, all of the above except `alarmtimer_freezer_off` was one
KernelSU module, `selinux_cosmetics`. The per-patch READMEs carry the
on-device evidence; this is only the map of what shipped when.

| version | what changed |
|---|---|
| v1 | the avc `find` / `getattr` allow rules, the `ImsProvisioningController` tag mute |
| v2 | reworked sepolicy set + `post-fs-data.sh` (0.9.4 cannot parse colon rules) |
| v3 | events-buffer audit fix, `mnld -> default_prop file open` |
| v4 | first MTK power-stack patches folded in (setMode, the eara_io tag mutes) |
| v5 | three vendor overlays + the tag mutes, verified with a full reboot |
| v5.1 | `libpowerhal.so`: the two absent foreground-pid nodes repointed at `/dev/null` |
| v5.2 | `libpowerhal.so`: the whole netdagent error block nop'ed (8 calls) + `libPowerHal-bt` pinned to `E` |
| v5.3 | `/vendor/bin/netdagent`: the daemon's own two `ERROR` lines nop'ed |

The v5.3 zip is in `release/legacy/`. Its four payload files are byte-identical
to the ones in this tree, so it is a valid fallback if a split module misbehaves.
