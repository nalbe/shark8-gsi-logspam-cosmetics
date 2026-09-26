# mtk-power-setmode

The Blackview Shark 8 runs an Android 13/14 AOSP GSI on the stock vendor image
(KernelSU 0.9.4, kernel `5.10.223-rama982-gki-v1.19-ksu`), and that mix makes
the MTK power HAL log a `[setMode]` error once per second, forever. This module
silences it with a binary patch of
`/vendor/lib64/android.hardware.power-service-mediatek.so`: zero functional
change, zero permissive domains, `/vendor` itself is never written. It is one of
the seven modules of the
[shark8-gsi-logspam-cosmetics](../README.md) project and the sole owner of that
one library.

## What it fixes

    E mtkpower@impl: [setMode] unknown type
    I mtkpower@impl: [setMode] type:6, enabled:0

Every ~1 s, forever, even on an idle desktop.

## Root cause

`surfaceflinger` (GSI) toggles `Mode::EXPENSIVE_RENDERING` (AIDL value **6**)
once per second; the vendor HAL implements a different, older `Mode` layout, so
mode 6 hits its `default:` arm and logs `unknown type`. Behaviorally nothing
happens either way - mode 6 was already a no-op.

## The fix

Fixed by patching the vendor library itself:
`vendor/lib64/android.hardware.power-service-mediatek.so` (19 KB overlay,
`/vendor` untouched, dm-verity happy). Stock md5
`40aea46435089ab1e2fc002d67f8ec2d` -> patched md5
`a52fb102917c13c0b15ed83a13598394`.

| file offset | stock | patched | effect |
|-------------|-------|---------|--------|
| 0x31F0 | `0x94000288` `bl __android_log_print` | `0xD503201F` `nop` | drops the entry `[setMode] type:N, enabled:N` INFO line for every mode |
| 0x31FC | `0x54000928` `b.hi 0x3320` | `0x54000BA8` `b.hi 0x3370` | out-of-range modes return `AStatus_newOk` silently |
| 0x1852 | `0x42` | `0x56` | jump table: mode 4 (VR) -> silent OK |
| 0x1854 | `0x42` | `0x56` | jump table: mode 6 (EXPENSIVE_RENDERING) -> silent OK |

Modes 2/3/5/7 keep their original code paths; only the shared INFO log line is
dropped. `patch_powerhal.ps1` rebuilds the patched library from the stock one
and validates every byte it touches.

## Overlay labels - why post-fs-data.sh exists

A zip install of this module used to bootloop the phone, hard. The patch itself
was never at fault; the label of the payload was.

`ksud module install` extracts zip payloads as `u:object_r:system_file:s0`, and
KernelSU 0.9.4 mounts the `/vendor` overlay with `seclabel`, so the linker sees
the replacement library carrying `system_file` instead of the stock
`vendor_file`. Vendor HAL domains are only granted `vendor_file`, so the power
HAL is denied on the very library it has to load:

    F/linker: CANNOT LINK EXECUTABLE "/vendor/bin/hw/vendor.mediatek.hardware.mtkpower@1.0-service":
              library "android.hardware.power-service-mediatek.so" not found: needed by main executable
    avc:  denied  { read } for  name="android.hardware.power-service-mediatek.so"
          dev="overlay" scontext=u:r:mtk_hal_power:s0
          tcontext=u:object_r:system_file:s0 tclass=file permissive=0

`init` restarts the service every 5 s, `android.hardware.power.IPower/default`
never registers, `sys.boot_completed` never reaches 1 and the device sits on the
boot animation forever. This module is the one that turns that into a brick,
because a missing power HAL blocks the whole boot.

`post-fs-data.sh` therefore chcon's the module's own `vendor/` tree to
`vendor_file` on every boot, which is what `apply.sh` already did for manual
installs - that is why the pre-split module never showed the problem: it had
always been installed by hand. `selinux-avc-rules` additionally carries
`allow mtk_hal_power system_file file ...` as a fallback for the window before
the relabel has run. Neither touches `/vendor`.

## Files

    module.prop     KernelSU module metadata (id: mtk_power_setmode)
    apply.sh        install the module + print the payload md5
    revert.sh       remove the module directory again
    post-fs-data.sh relabel the overlay payload to vendor_file (bootloop fix)
    patch_powerhal.ps1
                    host-side: rebuild the patched power HAL service .so
    vendor/lib64/android.hardware.power-service-mediatek.so
                    patched MTK power HAL (setMode logspam fix)

## Install

Option A, KernelSU Manager: flash
`../release/shark8_mtk_power_setmode_v1.0.zip`, then reboot.

Option B, in place on a rooted device:

    sh mtk-power-setmode/apply.sh
    adb reboot

`/vendor` is never written. The patched library is a KernelSU overlay, so it is
live only after the reboot.

## Verify

    adb root
    adb shell md5sum /vendor/lib64/android.hardware.power-service-mediatek.so
    adb shell getprop persist.log.tag.mtkpower@impl
    adb shell 'logcat -c'
    # screen off / screen on, or leave the phone idle on the desktop
    adb shell 'logcat -d'

Healthy: the md5 is the one `apply.sh` printed,
`a52fb102917c13c0b15ed83a13598394` (stock is
`40aea46435089ab1e2fc002d67f8ec2d`, 19776 bytes), and the idle or screen-toggle
window contains no `setMode` lines at all except the 2 legitimate
`[setMode] Disable All` / `Restore All` lines from the mode 7 handler, once per
screen toggle. `persist.log.tag.mtkpower@impl` still returns the stock `I`: this
module changes no log level. Broken: the stock md5 (overlay not mounted, reboot
missing) or any `[setMode] unknown type` / `[setMode] type:6, enabled:0` line
(patch not in place).

## Revert

    sh mtk-power-setmode/revert.sh
    adb reboot

or remove `mtk_power_setmode` in the KernelSU Manager and reboot. Nothing was
written to `/vendor`, so the stock library is back after the reboot.

## Rebuilding the payload

    adb pull /vendor/lib64/android.hardware.power-service-mediatek.so stock.so
    powershell -File mtk-power-setmode\patch_powerhal.ps1 -In stock.so -Out patched.so

The script fails loudly if the input is not the expected stock build: it checks
the size and the stock md5/size it is built against
(`40aea46435089ab1e2fc002d67f8ec2d`, 19776 bytes, build id
`0a3fb0b555d78fc46f077a86c86d1c5e`), the format string location and the
surrounding instructions around every byte it writes - the entry
`bl __android_log_print`, the `b.hi` dispatch and both jump-table bytes - before
touching anything, and it warns if the output md5 differs from the released
build, so a vendor update cannot be patched by accident.

## Verified on device (2026-09-21, v5, pre-split)

- Full reboot verification:
  `/vendor/lib64/android.hardware.power-service-mediatek.so` md5 =
  `a52fb102917c13c0b15ed83a13598394` (overlay mounted).
- 40 s idle + screen off/on: `libPowerHal` 0 lines, `mtkpower_client` 0 lines,
  `setMode` 2 lines (the legitimate `[setMode] Disable All` / `Restore All` from
  the mode 7 handler, once per screen toggle).
- Adding a file to an existing module directory does not show up in `/vendor`
  until reboot (KernelSU mounts the overlay paths it saw at boot) - new
  overlays need one reboot.

Provenance: these measurements were taken when this patch was section 5 of the
combined `selinux_cosmetics` module (v5, and unchanged since), and the payload
md5 is identical to the one verified in v5.3.

## Verified on device (2026-09-26, v1.1, split + relabel fix)

- Zip install of the split module set bootlooped until the payload relabel was
  added. With `post-fs-data.sh` in the zip: clean boot, `sys.boot_completed=1`
  on the first attempt, zero `mtk_hal_power` denials in `dmesg`.
- `ls -laZ /vendor/lib64/android.hardware.power-service-mediatek.so` reports
  `u:object_r:vendor_file:s0`, the same label as the stock libraries beside it.
- `logcat -b all -d | grep -c setMode` = 0, `libPowerHal` = 0,
  `mtkpower_client` = 0, and
  `vendor.mediatek.hardware.mtkpower@1.0-service` stays up instead of being
  restarted every 5 s.

## Ownership

This subdirectory is the only owner of
`/vendor/lib64/android.hardware.power-service-mediatek.so` in the project. Two
KernelSU modules must never overlay the same file, so any further patch of this
library belongs here and not in a new project. The tag-level mute of
`mtkpower@impl` is deliberately NOT done here (see
[../log-tag-mutes](../log-tag-mutes/README.md)): `[setMode] unknown type` is not
a log-level artifact, it is a mode the vendor HAL does not implement, so it is
fixed in the code path.
