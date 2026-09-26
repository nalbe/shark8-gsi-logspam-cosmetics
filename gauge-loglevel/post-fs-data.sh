#!/system/bin/sh
# gauge_loglevel (KernelSU post-fs-data.sh): drop the MT6358 fuel gauge driver's
# own log level to 0 at every boot.
#
# The node is a driver module parameter, i.e. a runtime value: it is back to the
# driver default after every reboot, so this has to run at every boot. The pwrap
# gauge device is up early, well before anything interesting logs, so a single
# pass in post-fs-data is enough and this returns immediately - no polling loop
# that could stall the other modules.
#
# SCOPE, honestly: this does NOT silence sgm4154x_dump_register, the SGM4154x
# charger IC dumping registers over I2C at ~4 lines/s. That function belongs to
# the charger driver and ignores this knob, and sgm415xx / mt6358_battery are
# built into vmlinux, so there is no .ko to patch - stopping it needs a vmlinux
# binary patch. See ../charger-loglevel/README.md.

GAUGE=/sys/devices/platform/soc/10026000.pwrap/10026000.pwrap:mt6366/mt6358-gauge/FG_daemon_log_level
LOG=/data/local/tmp/gauge_loglevel.log

if [ -w "$GAUGE" ]; then
  if echo 0 > "$GAUGE" 2>/dev/null; then
    echo "$(date) FG_daemon_log_level=$(cat "$GAUGE" 2>/dev/null)" >> "$LOG"
  fi
else
  echo "$(date) $GAUGE not writable, skipped" >> "$LOG"
fi

exit 0
