#!/bin/bash
# DEPRECATED (2026-08-25, stage 13): prod path — LACT:
# nvidia-card-setting.service (daemon variant) + image nvidia-lact
# (wrapper: resources/driver/lact/lact.sh). This script — fallback only;
# functionality is frozen.
# Env (default = prod state: OC on):
#   PWR_LIMIT=130 GPU_CLOCK_OFFSET=100 MEM_CLOCK_OFFSET=1000 FAN_TARGET_SPEED=40
#   MEM_CLOCK_OFFSET — effective DDR offset, *2 — driver quirk
set -x

PATH=${PATH}:/opt/nvidia/bin

PWR_LIMIT=${PWR_LIMIT:-130}
GPU_CLOCK_OFFSET=${GPU_CLOCK_OFFSET:-100}
MEM_CLOCK_OFFSET=${MEM_CLOCK_OFFSET:-1000}
FAN_TARGET_SPEED=${FAN_TARGET_SPEED:-40}

XPID=$(pidof Xorg)
if [ "$?" = "0" ] ; then
    DISPLAY=:$(cat /proc/$(pidof Xorg)/cmdline | awk -F: '{ print $2; }')
    [ "$DISPLAY" = ":" ] && DISPLAY=:0
else
    nvidia-xconfig -a --cool-bits=12 --allow-empty-initial-configuration --enable-all-gpus
    sed -i '/Section "Monitor"/a\    Option "CustomEDID" "DPF-1:/NEC-EA244WMi.edid"' /etc/X11/xorg.conf
    DISPLAY=:2
    chvt 8
    Xorg -config /tmp/xorg.conf $DISPLAY &
    /bin/sleep 2
fi

xpid=$(pidof Xorg)

export DISPLAY

nvidia-smi -pm 1

nvidia-smi -pl $PWR_LIMIT

nvidia-settings \
    -a "[gpu]/GPUGraphicsClockOffsetAllPerformanceLevels=$GPU_CLOCK_OFFSET" \
    -a "[gpu]/GPUMemoryTransferRateOffsetAllPerformanceLevels=$(( MEM_CLOCK_OFFSET * 2 ))" \
    -a "[gpu]/GPUFanControlState=1" \
    -a "[fan]/GPUTargetFanSpeed=$FAN_TARGET_SPEED"

[ "$DISPLAY" = ":2" ] && kill $xpid

chvt 1
