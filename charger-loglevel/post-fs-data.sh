#!/system/bin/sh
# charger_loglevel (KernelSU post-fs-data.sh): drop the MTK charger driver's own
# log level to 0 at every boot.
#
# /sys/devices/platform/charger/charger_log_level is a driver module parameter,
# i.e. a runtime value: it is back to the driver default after every reboot, so
# this has to run at every boot. post-fs-data is early enough - the charger
# platform device is up long before anything interesting logs - and a single
# pass is enough, so this returns immediately and never stalls the other modules.
#
# SCOPE, honestly: this does NOT silence sgm4154x_dump_register, the SGM4154x
# charger IC dumping registers 0x0..0xf over I2C at ~4 lines/s. That function
# ignores this knob (both 0 and 2 were tried, no change in the dump rate), and
# sgm415xx / mt6358_battery are built into vmlinux: grep -rls
# sgm4154x_dump_register across all 181 modules in /vendor_dlkm returns nothing,
# so there is no file to patch. Stopping it needs a vmlinux binary patch (NOP the
# printk), which requires the kernel image out of vendor_boot and a matching
# vmlinux analysis. Not done. The dump is also charge-state driven: with the
# battery at 100% and the reported current oscillating around zero
# (current = -20 / -12 / +96 mA) every state change triggers a fresh pass, and
# it goes quiet off charge.
#
# battery/log_level was already 0 on the stock image, so there is nothing to do
# there.

CHARGER=/sys/devices/platform/charger/charger_log_level
LOG=/data/local/tmp/charger_loglevel.log

if [ -w "$CHARGER" ]; then
  if echo 0 > "$CHARGER" 2>/dev/null; then
    echo "$(date) charger_log_level=$(cat "$CHARGER" 2>/dev/null)" >> "$LOG"
  fi
else
  echo "$(date) $CHARGER not writable, skipped" >> "$LOG"
fi

exit 0
