#!/system/bin/sh
# log_tag_mutes: hold the four log tags at level E (errors only) at every boot.
#
# The props are persistent, so this only has to survive a ROM flash or an
# accidental `setprop` - but the tags must be in place before the power HAL
# starts, otherwise the first boot window keeps logging the full INFO flood,
# so they are set in post-fs-data (the earliest script phase there is).
#
# What each tag silences on the Blackview Shark 8 GSI:
#
#   ImsProvisioningController
#       com.android.phone asks ImsProvisioningController whether provisioning
#       is required; getTechsFromCarrierConfig() reads an int-array out of an
#       empty carrier-config bundle and logs W "getTechsFromCarrierConfig
#       failed" every ~30 s. The fallback (not required) is the correct
#       behavior for an operator that does not gate IMS.
#
#   mtkpower_client
#       /vendor/bin/eara_io_service (MTK EARA-IO QoS) renews a 500 ms
#       perf_lock_acq every ~100 ms while assets load: "perf_lock_acq, hdl:..,
#       dur:500, num:.., tid:..", "ret_hdl:..", and the DEBUG list dump.
#       ~224 lines per game load.
#
#   libPowerHal
#       the same QoS renewals seen from the library: "[perfLockAcq] idx:..",
#       "[PE] eara_io_service update cmd:..", "[setGPUFreq]". ~418 lines per
#       game load. Real E-level libPowerHal errors keep printing - the binary
#       patches for the ones that are not log-level artifacts live in
#       ../libpowerhal-noise.
#
#   libPowerHal-bt
#       the second tag libpowerhal.so logs under (the "libPowerHal-bt" literal
#       at .rodata 0xD48C). Only the BT low-latency path uses it: perfScnEnable
#       of PERF_RES_NET_BT_AUDIO_LOW_LATENCY logs 3 INFO lines per notify
#       ("bt a2dp low latency enter = 1, data:0x..", "open provider cb",
#       "get provider successfully"). A hyphen is fine in a property name -
#       setprop accepts it and the HAL picks it up immediately.
#
# Tags containing '@' (eara_io@boost, eara_io@eval) are NOT handled here: the
# original claim that '@' is illegal in a property name was wrong (the stock
# image ships persist.log.tag.mtkpower@impl=I and setting it to V works), but
# the tag route was never re-tested against the stock lib_eara_io_scndet.so, so
# the verified binary patch in ../eara-io-scene-detector stays.
RESETPROP=/data/adb/ksu/bin/resetprop
[ -x "$RESETPROP" ] || RESETPROP=setprop

$RESETPROP persist.log.tag.ImsProvisioningController E
$RESETPROP persist.log.tag.libPowerHal E
$RESETPROP persist.log.tag.libPowerHal-bt E
$RESETPROP persist.log.tag.mtkpower_client E

exit 0
