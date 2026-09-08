# shark8-gsi-logspam-cosmetics

One cosmetic patch for the Blackview Shark 8 running an Android 13/14 AOSP GSI
on the stock vendor image (KernelSU 0.9.4, kernel `5.10.223-rama982-gki-v1.19-ksu`).
Silences recurring sources of logspam caused by GSI/vendor mixing.
Zero functional change, zero permissive domains.

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

## Layout

    module/
      module.prop       KernelSU module metadata
      sepolicy.rule     SELinux allow-rules, classic format (space-separated)
      post-fs-data.sh   re-applies rules at boot + flushes the AVC cache
    scripts/
      apply.sh          device-side: copy module + apply rules now + persist IMS tag
      revert.sh         device-side: remove module + reset IMS log tag
    shark8_gsi_logspam_cosmetics_v2.zip
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
`shark8_gsi_logspam_cosmetics_v2.zip`, then reboot. `post-fs-data.sh` applies
the rules at boot.

Option B, in-place push on a rooted device (`adb root`):

    sh scripts/apply.sh

This copies the module files into `/data/adb/modules/selinux_cosmetics`,
applies the sepolicy rules immediately, flushes the AVC cache, and persists
the IMS log tag prop. No reboot required.

The IMS log tag prop is set separately (persists, no reboot needed) by
`apply.sh`, or manually:

    setprop persist.log.tag.ImsProvisioningController E

## Revert

In the KernelSU Manager remove the `selinux_cosmetics` module and reboot, or:

    sh scripts/revert.sh   # removes module + resets IMS tag

The IMS log tag can be re-enabled at any time (no reboot needed):

    setprop persist.log.tag.ImsProvisioningController ""

## Verified on device (2026-09-04)

- Before: `avc: denied { getattr }` bursts on radio/gmscore_app/platform_app/
  priv_app/untrusted_app/bluetooth/system_app/mediaprovider/su every few
  seconds, `zygote_tmpfs:file { write }` from CachedAppOptimizer, and `find`
  denials from the fingerprint/radio HALs on `default_android_hwservice`.
- After reboot with the module: rules auto-apply at boot
  (`post-fs-data.sh`); 0 recurring `avc: denied` in dmesg across a full
  boot-to-bootcycle window. The only residual denials are a one-off
  `adbroot`/`adbd` capability pair created when lifting `adb root`, which is
  intentional and not logspam.
