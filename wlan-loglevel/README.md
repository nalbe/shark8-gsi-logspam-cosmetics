# wlan-loglevel

Silences the MTK conninfra WLAN driver log firehose on the Blackview Shark 8
GSI. No kernel module is patched, no binary is modified: two `/proc` writes and
a revert.

Module id `wlan_loglevel`, part of
[shark8-gsi-logspam-cosmetics](../README.md). Split out of the old combined
`shark8_quietlogs` module; the charger and fuel-gauge knobs that used to live in
the same `service.sh` are now [`charger-loglevel`](../charger-loglevel) and
[`gauge-loglevel`](../gauge-loglevel).

Target driver: `/vendor_dlkm/lib/modules/wlan_drv_gen4m_6789.ko`, vendor prop
`ro.vendor.wlan.gen = gen4m_6789`.

## Symptom

`dmesg` fills with `[wlan]` lines while there is any WiFi traffic (counted with
`adb shell dmesg`, patterns in the last 300 lines):

```
[wlan][2489] kalPerMonUpdate:(SW4 INFO) <1016ms> Tput: 1078328(1.029mbps) ...
[wlan][2490] kalDumpHifStats:(HAL INFO) I[8686 0] T[411 411 411 / 3170 ...] ...
[wlan][2490] halSetFWOwn:(INIT INFO) FW OWN:1, IntSta:0x10000010
[wlan][2490] halSetDriverOwn:(INIT INFO) DRIVER OWN Done[1102 us]
[wlan][2489] cnmTimerStartTimer:(CNM INFO) [WLAN-LP] Start timer ... 200 ms
```

Roughly 6-8 lines per second, scaling with throughput. At the same time the
`wlan0` IRQ (GICv3 441) runs at ~41/s and the phone never reaches a quiet
suspend state. This one is not only cosmetic: the IRQ keeps the device awake.

## Root cause

The driver keeps a per-module debug level mask, and the stock value is **0x2f
on every module** - `ERROR|WARN|STATE|EVENT|INFO`, so INFO is enabled for the
whole driver:

```
$ adb shell cat /proc/net/wlan/dbgLevel
TEMP|LOUD|INFO|TRACE | EVENT|STATE|WARN|ERROR
bit7|bit6|bit5|bit4 | bit3|bit2|bit1|bit0
Usage: Module Index:Module Level, such as 0x00:0xff
DBG_INIT_IDX   (0x00): 0x2f   DBG_HAL_IDX   (0x01): 0x2f
...
```

On top of that the performance monitor is force-enabled and dumps HIF stats once
a second on its own, which is the standalone `kalPerMonUpdate` /
`kalDumpHifStats` cadence.

## Fix

Set every module to **0x03** (`ERROR|WARN` only) and turn the performance
monitor back to its default strategy. Real faults still reach the log, the
chatter does not.

| node | stock | set to | effect |
|---|---|---|---|
| `/proc/net/wlan/dbgLevel` | `0x2f` per module, 32 modules | `0x03` per module | drops STATE/EVENT/INFO/TRACE/LOUD/TEMP for the whole driver |
| `/proc/net/wlan/autoPerfCfg` | `ForceEnable:1` (always enable) | `ForceEnable:0` (default strategy) | stops the 1 Hz HIF stats dump |

### The trap: the help text lies about the module count

`cat /proc/net/wlan/dbgLevel` only *documents* `0x00..0x0d`, so it is natural to
write fourteen entries. That is not enough - the driver actually has **32**
modules, and the undocumented ones include `DBG_CNM_IDX (0x10)`, which is
exactly where the `cnmTimer*` chatter lives. Read the node back after writing
and the rest is still at `0x2f`:

```
DBG_HEM_IDX  (0x0c): 0x03   DBG_AIS_IDX  (0x0d): 0x03
DBG_RLM_IDX  (0x0e): 0x2f   <-- still loud, only 14 were written
...
DBG_CNM_IDX  (0x10): 0x2f   <-- cnmTimerStartTimer lives here
...
DBG_NIC_IDX  (0x1f): 0x2f
```

So the module writes `0x00` through `0x1f`. Full undocumented tail, for whoever
does this again:

| idx | name | idx | name | idx | name | idx | name |
|-----|------|-----|------|-----|------|-----|------|
| 0x00 | INIT | 0x08 | SW1  | 0x10 | CNM  | 0x18 | SEC  |
| 0x01 | HAL  | 0x09 | SW2  | 0x11 | RSN  | 0x19 | BOW  |
| 0x02 | INTR | 0x0a | SW3  | 0x12 | BSS  | 0x1a | WAPI |
| 0x03 | REQ  | 0x0b | SW4  | 0x13 | SCN  | 0x1b | ROAMING |
| 0x04 | TX   | 0x0c | HEM  | 0x14 | SAA  | 0x1c | TDLS |
| 0x05 | RX   | 0x0d | AIS  | 0x15 | AAA  | 0x1d | PF   |
| 0x06 | RFTEST | 0x0e | RLM | 0x16 | P2P  | 0x1e | OID  |
| 0x07 | EMU  | 0x0f | MEM  | 0x17 | QM   | 0x1f | NIC  |

The writable nodes are in `/proc/net/wlan/`, **not** `/proc/net/wlan0/` - the
`wlan0` directory only holds the read-only `met_ctrl` and `met_port`.

## Result

Pattern counts in the last 300 `dmesg` lines, same boot, before vs after:

| pattern | before | after |
|---|---|---|
| `kalPerMonUpdate` | 20 | **0** |
| `halSetFWOwn` | 17 | **0** |
| `halSetDriverOwn` | 16 | **0** |
| `kalDumpHifStats` | 11 | **0** |
| `cnmTimerStartTimer` | ~2/s | **0** |

WiFi is untouched: `dumpsys wifi` reports `Wi-Fi is enabled`, and
`/proc/net/wlan/mcr` is unchanged at `0x011c0031` before and after.

## What this does NOT fix

- `sgm4154x_dump_register` (~4 lines/s) is the charger IC dumping its registers
  over I2C. It survives this module and every log-level knob; it is built into
  vmlinux, so the only fix is a vmlinux patch. See
  [`charger-loglevel`](../charger-loglevel/README.md).
- `[wdk-c]` per-CPU dumps come from `aee_hangdet`. **Do not `rmmod
  aee_hangdet`** - it looks safe (`refcnt 0` in `/proc/modules`, no
  `/sys/module/aee_hangdet/parameters` at all) but it reboots the phone.
  Verified the hard way; the pstore capture says
  `reboot: Restarting system with command 'shell'`. It has no module parameters,
  so there is no knob for it either. Left alone on purpose, and noted in
  `service.sh` so the next person does not try.
- `ro.vendor.wlan.standalone.log = y` is another possible lever (it routes
  driver logs through the standalone kernel path). Not used: the level mask is
  the cleaner fix.

## Install

Flash `release/shark8_wlan_loglevel_v1.0.zip`, or install in place:

    sh wlan-loglevel/apply.sh

`/proc` values do not persist, so `service.sh` re-asserts at every boot; a live
apply means you do not have to reboot to see it now. `service.sh` polls for the
node instead of sleeping a fixed amount, because `/proc/net/wlan/` only exists
once the driver is up and a fixed delay silently loses the write on a slow boot.
It re-asserts once after 150 s, because WLAN can be reloaded (roam, driver
restart) and the mask resets with it.

If the old combined module is still installed, remove it - it writes the same
`dbgLevel` node:

    adb shell su -c 'rm -rf /data/adb/modules/shark8_quietlogs'

## Verify

    adb shell cat /proc/net/wlan/dbgLevel | grep -c 0x2f    # 0
    adb shell cat /proc/net/wlan/dbgLevel | tail -6         # every entry 0x03
    adb shell dmesg | grep -c kalPerMonUpdate                # 0
    adb shell cat /data/local/tmp/wlan_loglevel.log          # applied lines

## Revert

    sh wlan-loglevel/revert.sh

writes `0x2f` back to all 32 modules and `ForceEnable:1` to `autoPerfCfg`, then
removes `/data/adb/modules/wlan_loglevel`. No reboot needed: the mask is a
runtime value and the next boot starts at stock anyway.
