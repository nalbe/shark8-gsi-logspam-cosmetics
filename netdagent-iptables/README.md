# netdagent-iptables

Binary patch for `/vendor/bin/netdagent` on the Blackview Shark 8 running an
Android 13/14 AOSP GSI on the stock vendor image (KernelSU 0.9.4, kernel
`5.10.223-rama982-gki-v1.19-ksu`). This subdirectory ships the KernelSU module
`netdagent_iptables`, which owns exactly one file: the vendor netdagent daemon.
It is one of seven modules of the
[shark8-gsi-logspam-cosmetics](../README.md) project; a second module must never
overlay the same file, so the daemon is patched here and nowhere else.

## What it fixes

    E NetdagentIptables: exec() res=0, status=256
    E NetdagentService: run command firewall failed

## Root cause

The daemon runs each `firewall` command with `/system/bin/iptables-wrapper-1.0`;
the exec succeeds (`res=0`) and the wrapper exits 1 (`status=256` is waitpid's
raw value for exit code 1), so `run_command()` logs the failure and the caller
logs it again. There is no AVC denial and no further diagnostic in that path,
only these two lines - a real functional failure of this GSI/vendor mix, not a
log-level artifact, and `E` cannot be muted by a tag. Hiding them makes the log
clean; it does not make the net hints work (see
[Residual](#residual-not-fixed-here) below).

## The patch

`vendor/bin/netdagent`, stock md5 `6e3f6b430386eb032715038bf7544120`
(55616 bytes) -> patched md5 `f58dbc8877c401ed4d2bcf9d0436bb42`.

| file offset | stock | patched | message dropped |
|-------------|-------|---------|-----------------|
| 0x56E0 | `0x940017D0` `bl __android_log_print` | `0xD503201F` `nop` | `run command %s failed`, tag `NetdagentService` (0x2F5D), fmt 0x2AAF |
| 0xB0BC | `0x94000159` `bl __android_log_print` | `0xD503201F` `nop` | `exec() res=%d, status=%d`, tag `NetdagentIptables` (0x3639), fmt 0x24BC |

Both sites fall through to instructions that define nothing the log call could
have defined (`mov w22, #-1` and `ldrb w8, [sp, #0x18]`), so only the print is
lost; the iptables call, its status and the return values stay. Each format
string is referenced exactly once in the whole binary (checked with
`llvm-objdump -d`). `patch_netdagent.ps1` re-checks the stock md5 and
size, the four literals, both expected `bl` words and - via imm26 decode - that
each call targets `__android_log_print@plt` (0xB620).

## SELinux

The module file keeps `u:object_r:netdagent_exec:s0` (the init service enters via
that type, `/(vendor|system/vendor)/bin/netdagent` in `vendor_file_contexts`),
so `apply.sh` re-labels it after the generic `chcon -R vendor_file` over
`vendor/`. A plain `vendor_file` label would make init refuse to execute the
daemon.

## Residual (not fixed here)

* the `udp_socket` avc denial of the netdagent domain (seen once, permissive=0);
  adding an allow rule cannot fix the dispatch because the daemon's socket is
  not created at all (`socket netdagent` is commented out in
  `/vendor/etc/init/netdagent.rc`).

That is the reason the net hints do not work. It is deliberately not patched
here: this module owns the log lines, not the daemon's socket.

## Relationship to the other modules

* [`../libpowerhal-noise/README.md`](../libpowerhal-noise/README.md) - the
  library-side half of the same net-boost trigger (8 `bl __android_log_print`
  calls in `libpowerhal.so`).
* [`../log-tag-mutes/README.md`](../log-tag-mutes/README.md) - the tag mute.
* The trigger itself (feeding `IMtkPower::notifyAppState` a foreground app the
  GSI framework no longer sends) lives in the separate shark8-gamemode-gsi
  project.

## Files

    module.prop             KernelSU module metadata (id: netdagent_iptables)
    vendor/bin/netdagent    patched netdagent daemon (2 nop'ed log calls;
                            keeps u:object_r:netdagent_exec:s0)
    apply.sh                install the overlay module + print the payload md5
    revert.sh               remove the module, the stock daemon returns on reboot
    post-fs-data.sh         relabel the overlay payload: vendor_file for the
                            directories, netdagent_exec for the binary
    patch_netdagent.ps1     host-side: rebuild the patched netdagent daemon

## Overlay labels

This payload needs two things fixed that a zip install gets wrong by default, and
both were invisible until 2026-09-26, when the split-module install left the
service dead.

**The label.** `ksud module install` extracts zip payloads as
`u:object_r:system_file:s0`, and KernelSU mounts the `/vendor` overlay with
`seclabel`, so init executes the patched daemon with the wrong label. And the
stock label is not `vendor_file` either - `netdagent` is an init service
(`/vendor/etc/init/netdagent.rc`) with its own exec type, so the binary needs
`u:object_r:netdagent_exec:s0` and the directories around it `vendor_file`.

**The exec bit.** `init` has to exec this file. Land it as `0644` and the
service never starts at all:

    init: cannot execv('/vendor/bin/netdagent'). See the 'Debugging init' section
          of init's README.md for tips: Permission denied
    init: Service 'netdagent' (pid 3651) exited with status 127
    apexd: Native process 'netdagent' is crashing. Attempting a revert

The three `vendor/lib64` payloads are only `dlopen`'d, so they are fine at
`0644`; this daemon is not. `build.ps1` ships `vendor/bin/` as `0755`,
`apply.sh` chmods it, and `post-fs-data.sh` does it a third time for the case
where a reader ignores the zip mode.

`post-fs-data.sh` applies label and mode on every boot, exactly like
`apply.sh` does for manual installs - which is why the pre-split module never
showed either problem: it was only ever installed by hand. See
[../mtk-power-setmode](../mtk-power-setmode/README.md) for the label incident
that bootlooped the device.

## Install

Option A, KernelSU Manager: flash
`../release/shark8_netdagent_iptables_v1.0.zip`, then reboot.

Option B, in place on a rooted device:

    sh netdagent-iptables/apply.sh
    adb reboot

`/vendor` is never written. The patched daemon is a KernelSU overlay, so it is
live only after the reboot - adding an overlay file to a module directory does
not show up in `/vendor` before the next boot.

## Verify

After the reboot, on the device as root (`adb root`, then `adb shell`):

    md5sum /vendor/bin/netdagent
    # f58dbc8877c401ed4d2bcf9d0436bb42  /vendor/bin/netdagent
    # stock was 6e3f6b430386eb032715038bf7544120, 55616 bytes

    ls -Z /vendor/bin/netdagent
    # u:object_r:netdagent_exec:s0 ... /vendor/bin/netdagent
    pidof netdagent
    getprop init.svc.netdagent
    # running

The label plus a non-empty `pidof netdagent` plus `init.svc.netdagent` =
`running` is the check that the overlay does not break the init service.

Then the net-boost trigger, which is what produces the lines in the first place
(`powercli` comes from the separate shark8-gamemode-gsi project). Lift the tag
to `V` and restart the power HAL first, so nothing is hidden by the level
filter:

    setprop persist.log.tag.libPowerHal V
    setprop ctl.restart power-hal-1-0
    powercli notify <pack> <act> <pid> 1 <uid>
    powercli notify <pack> <act> <pid> 0 <uid>
    logcat -d

State 1 focuses the app, state 0 releases it. Healthy: **0** `Netdagent` lines
in the whole buffer, where v5.2 produced 2x
`NetdagentIptables: exec() res=0, status=256` +
`NetdagentService: run command firewall failed` for the same trigger, while 8
`perfNotifyAppState` and 27 `update cmd` lines prove the path still runs.

## Revert

    sh netdagent-iptables/revert.sh
    adb reboot

or remove `netdagent_iptables` in the KernelSU Manager. Nothing was written to
`/vendor`, so after the reboot the stock daemon is back.

## Rebuilding the payload

    adb pull /vendor/bin/netdagent stock-netdagent
    powershell -File netdagent-iptables\patch_netdagent.ps1 -In stock-netdagent -Out patched-netdagent

The script fails loudly if the input is not the expected stock build (it checks
the stock md5 and size, every literal it touches, and the decoded `bl` target
for both nop patches), so a vendor update cannot be patched by accident.

## Verified on device (2026-09-21, v5.3, pre-split)

- Verified after a reboot: `/vendor/bin/netdagent` md5 =
  `f58dbc8877c401ed4d2bcf9d0436bb42` (overlay mounted), label
  `u:object_r:netdagent_exec:s0`, `pidof netdagent` = 1590,
  `init.svc.netdagent` = `running` - the overlay does not break the init service.
- Same trigger with the tag at `V` and the power HAL restarted: **0** `Netdagent`
  lines in the whole buffer, where v5.2 produced 2x
  `NetdagentIptables: exec() res=0, status=256` +
  `NetdagentService: run command firewall failed`. Still **0**
  `dispatchNetdagentCmd`, `SetPriorityWithUID`, **0** `empty slot`, **0**
  `sprintf fail`; the one surviving `NetdAgentCmd` line is the DEBUG
  `[NetdAgentCmd] netdagent firewall priority_set_uid 10123`, below the tag
  level. Proof that the path still runs: 8 `perfNotifyAppState` and 27
  `update cmd` lines.
- Byte diff against the stock daemon: exactly 2 words (0x56E0, 0xB0BC), each
  `bl __android_log_print` -> `nop`.

All three measurements were taken when this patch was section 9 of the single
`selinux_cosmetics` module (v5.3), before the project was split into one module
per patch.

## Ownership

This subdirectory is the only owner of `/vendor/bin/netdagent` in the project.
Two KernelSU modules must never overlay the same file, so any further change to
the daemon's own logging belongs here, not in a new project.
