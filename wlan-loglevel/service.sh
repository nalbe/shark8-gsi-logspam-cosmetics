#!/system/bin/sh
# wlan_loglevel (KernelSU service.sh): silence the MTK conninfra WLAN driver
# with the driver's own runtime knobs. No .ko is patched, nothing is written
# outside /proc, revert is revert.sh.
#
# TARGET 1 - /proc/net/wlan/dbgLevel
#   Per-module debug level mask, written as "<idx>:<level>". Stock is 0x2f on
#   every module, and 0x2f = ERROR(bit0)|WARN(bit1)|STATE(bit2)|EVENT(bit3)|
#   INFO(bit4) - INFO is enabled for the whole driver, which is the firehose:
#
#       [wlan][2489] kalPerMonUpdate:(SW4 INFO) <1016ms> Tput: 1078328(1.029mbps)
#       [wlan][2490] kalDumpHifStats:(HAL INFO) I[8686 0] T[411 411 411 / 3170
#       [wlan][2490] halSetFWOwn:(INIT INFO) FW OWN:1, IntSta:0x10000010
#       [wlan][2489] cnmTimerStartTimer:(CNM INFO) [WLAN-LP] Start timer ... 200 ms
#
#   ~6-8 lines per second while there is any WiFi traffic, and it scales with
#   throughput. 0x03 keeps ERROR and WARN, so real faults still reach the log.
#
#   The trap: `cat /proc/net/wlan/dbgLevel` prints help text that documents only
#   0x00..0x0d, so writing fourteen entries looks complete. It is not - the
#   driver has 32 modules, and the undocumented tail contains DBG_CNM_IDX 0x10,
#   which is exactly where the cnmTimer* chatter lives. Read the node back after
#   writing and the entries from 0x0e up are still 0x2f. So this writes 0x00
#   through 0x1f, 32 writes.
#
# TARGET 2 - /proc/net/wlan/autoPerfCfg
#   The driver's performance monitor is force-enabled and dumps HIF stats once a
#   second by itself. "ForceEnable:0" restores its default strategy, which is
#   what removes the standalone kalPerMonUpdate/kalDumpHifStats cadence. Stock
#   behaviour is ForceEnable:1 (always enable).
#
# MEASURED on this device, counts per 300 dmesg lines, same boot:
#   kalPerMonUpdate 20 -> 0    halSetFWOwn       17 -> 0
#   kalDumpHifStats  11 -> 0    halSetDriverOwn   16 -> 0
#   cnmTimerStartTimer ~2/s -> 0
#   wlan0 IRQ (GICv3 441) ~41/s -> quiet suspend. WiFi stays associated, wlan0
#   keeps its address, and /proc/net/wlan/mcr is unchanged at 0x011c0031.
#
# NOT TOUCHED on purpose: aee_hangdet. Its [wdk-c] per-CPU dumps are also noise
# and it looks unloadable (refcnt 0 in /proc/modules, no /sys/module/aee_hangdet
# /parameters at all), but `rmmod aee_hangdet` reboots the phone. Verified the
# hard way, pstore says "reboot: Restarting system with command 'shell'".
# It has no module parameters, so there is no knob for it either.
#
# The writable nodes are in /proc/net/wlan/, not /proc/net/wlan0/ - the wlan0
# directory only holds the read-only met_ctrl and met_port.

DBG=/proc/net/wlan/dbgLevel
AUTO=/proc/net/wlan/autoPerfCfg
LOG=/data/local/tmp/wlan_loglevel.log

# ERROR(bit0) + WARN(bit1) only.
LEVEL=0x03

IDX="0x00 0x01 0x02 0x03 0x04 0x05 0x06 0x07 0x08 0x09 0x0a 0x0b 0x0c 0x0d \
0x0e 0x0f 0x10 0x11 0x12 0x13 0x14 0x15 0x16 0x17 0x18 0x19 0x1a 0x1b \
0x1c 0x1d 0x1e 0x1f"

apply() {
  if [ ! -w "$DBG" ]; then
    echo "$(date) wlan node not present yet, skipped" >> "$LOG"
    return 0
  fi
  for i in $IDX; do
    echo "$i:$LEVEL" > "$DBG" 2>/dev/null
  done
  if [ -w "$AUTO" ]; then
    echo ForceEnable:0 > "$AUTO" 2>/dev/null
  fi
  left=$(grep -c '0x2f' "$DBG" 2>/dev/null)
  echo "$(date) applied wlan_level=$LEVEL on 32 modules, autoPerfCfg=0, still_0x2f=$left" >> "$LOG"
  return 0
}

# The /proc/net/wlan nodes only exist once the driver is up, and a fixed sleep
# silently loses the write on a slow boot, so poll for the node instead.
n=0
while [ "$n" -lt 60 ]; do
  if [ -e "$DBG" ]; then
    apply
    break
  fi
  sleep 3
  n=$((n + 1))
done

# WLAN can be reloaded later (roam, driver restart) and the mask resets with
# it. Re-assert once, then stay quiet.
sleep 150
apply
exit 0
