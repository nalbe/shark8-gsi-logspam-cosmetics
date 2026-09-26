# selinux-avc-rules

Silences the recurring SELinux `avc: denied` audit spam that the GSI/vendor mix
produces on the Blackview Shark 8 (Android 13/14 AOSP GSI on the stock vendor
image, kernel `5.10.223-rama982-gki-v1.19-ksu`). Ships as its own KernelSU
module, `selinux_avc_rules`, and is one of seven modules of the
[shark8-gsi-logspam-cosmetics](../README.md) project.

Every rule here is a plain `allow`. No domain is made permissive, nothing is
masked, and no audit event is dropped - the rules restore permissions that the
GSI/vendor mix lost, so what stops logging is the denials that were never real.

## What it fixes

### 1. SELinux avc find denials on nonexistent hwservices

`system_app` (telephony) probes vendor radio hwservices this chipset does not
provide (samsung_slsi/sprd/huawei/qti interfaces) and the fingerprint HAL
probes oppo/oplus hwservices; every miss lands on the
`default_android_hwservice` fallback context and floods auditd with
`{ find }` denials. Allowed via the classic-format rules in `sepolicy.rule`:

    allow system_app default_android_hwservice hwservice_manager find
    allow system_app default_android_service service_manager find
    allow radio default_android_hwservice hwservice_manager find
    allow radio default_android_service service_manager find

### 2. Bonus: periodic process-getattr audit spam

The same mixing also makes `system_server`/`surfaceflinger`/`vold` audit
`getattr` on foreign domains (radio, gmscore_app, platform_app, priv_app,
untrusted_app, bluetooth, system_app, mediaprovider, su, ...) every few
seconds, plus a `zygote_tmpfs` write from `CachedAppOptimizer`. Same
allow-rule treatment, in classic (space-separated) format so that old and
new KernelSU both parse them.

### 3. events-buffer audit flood (notification LED daemon feed)

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

## Why classic (space-separated) sepolicy.rule syntax

KernelSU 0.9.4's `ksud` parser does not understand the magisk colon form
`allow src target:class perm` (it fails with `Failed to parse policy
statement`), it only accepts `allow src target class perm`. Newer KernelSU
(v1.0.0+) supports both, so shipping classic syntax keeps the module working
across versions. Additionally 0.9.4 has no `reset_avc_cache()`: once a denial
has been cached, it keeps firing even after the rule is applied, so the
`post-fs-data.sh` script toggles enforcing off/on to flush the cache.

## Files

    module.prop     KernelSU module metadata (id=selinux_avc_rules)
    sepolicy.rule   the allow rules, classic space-separated format
    post-fs-data.sh boot-time re-apply through ksud + AVC cache flush
    apply.sh        install the module + apply the rules live
    revert.sh       remove the module (applied rules need a reboot to go away)

## Install

Option A, KernelSU Manager: flash
`../release/shark8_selinux_avc_rules_v1.0.zip`, then reboot.

Option B, in place on a rooted device:

    sh selinux-avc-rules/apply.sh

This copies the module files, applies the rules immediately through
`ksud sepolicy apply` and flushes the stale AVC cache. Live immediately - no
reboot needed for the rules themselves.

## Verify

    adb shell 'logcat -b events -d | grep -c "avc: denied"'
    adb shell 'logcat -b main -d | grep -c "avc: denied"'
    adb shell 'ls -l /data/adb/modules/selinux_avc_rules'
    adb shell 'grep -c "^allow" /data/adb/modules/selinux_avc_rules/sepolicy.rule'

Healthy: `0` in both logcat buffers over a live window (one-shot denials that
are intentional - the `adbroot`/`adbd` capability pair while rooted adb is up -
are allowed for), the rule count matches `sepolicy.rule`, and the module
directory is present.

If a denial still shows up, it is a new one: add the rule, then

    adb shell /data/adb/ksud sepolicy apply /data/adb/modules/selinux_avc_rules/sepolicy.rule
    adb shell 'echo 0 > /sys/fs/selinux/enforce; echo 1 > /sys/fs/selinux/enforce'

(the second command is the AVC cache flush; it is only needed on 0.9.4).

## Revert

    sh selinux-avc-rules/revert.sh
    adb reboot

or remove `selinux_avc_rules` in the KernelSU Manager. Rules that are already
in the kernel policy cannot be un-applied from userspace, so the reboot is what
actually restores the stock behavior - which is the point: without the rules
the denials come back.

## Verified on device (2026-09-15, v3, pre-split)

- Module (then: `selinux_cosmetics` v3, adds `mnld -> default_prop file open`).
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
- v5 boot window (2026-09-21) exposed three denials the earlier runs had not
  (`priv_app -> gmscore_app dir search`, `priv_app -> gmscore_app file open`,
  `gmscore_app -> adbd_prop`/`system_adbd_prop file open`); the rules were
  added, the whole file applies cleanly via `ksud sepolicy apply` in the
  classic format, and the next 60 s window shows **0** `avc:` lines after the
  usual enforce toggle to flush the stale deny cache.
  `grep -c '^allow' sepolicy.rule` is the authoritative rule count.

## Ownership

This subdirectory is the only owner of `sepolicy.rule` in the project: it is
the only module that touches SELinux policy, and the only module that flips
`/sys/fs/selinux/enforce`. Two KernelSU modules must never patch the same
file, and a second module with its own `sepolicy.rule` would make the AVC
cache flush happen twice per boot for no reason - so any further avc rule
belongs here.
