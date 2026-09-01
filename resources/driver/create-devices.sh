#!/bin/bash
set -euo pipefail

function fail() {
    echo "create-devices: $*" >&2
    exit 1
}

MAJOR_NVIDIA=$(awk '$2 == "nvidia" {print $1; exit}' /proc/devices)
MAJOR_UVM=$(awk '$2 == "nvidia-uvm" {print $1; exit}' /proc/devices)
MAJOR_CAPS=$(awk '$2 == "nvidia-caps" {print $1; exit}' /proc/devices)
[ -n "$MAJOR_NVIDIA" ] || fail "nvidia major not found in /proc/devices"
[ -n "$MAJOR_UVM" ] || fail "nvidia-uvm major not found in /proc/devices"
[ -n "$MAJOR_CAPS" ] || fail "nvidia-caps major not found in /proc/devices"

[ -d /proc/driver/nvidia/gpus ] || fail "/proc/driver/nvidia/gpus is missing, is the nvidia module loaded"
GPUS=$(ls /proc/driver/nvidia/gpus | wc -l)
[ "$GPUS" -ge 1 ] || fail "no GPUs found in /proc/driver/nvidia/gpus"

function create_device() {
    local dev=$1
    local max=$2
    local min=${3:-0}
    local mode=${4:-660}

    [ -c $1 ] || \
	mknod -m $mode $dev c $max $min
}

i=0
while [ "$i" -lt "$GPUS" ]; do
    create_device /dev/nvidia$i "$MAJOR_NVIDIA" "$i"
    i=$((i + 1))
done
create_device /dev/nvidiactl "$MAJOR_NVIDIA" 255

create_device /dev/nvidia-uvm "$MAJOR_UVM"
create_device /dev/nvidia-uvm-tools "$MAJOR_UVM" 1

mkdir -p /dev/nvidia-caps
create_device /dev/nvidia-caps/nvidia-cap1 "$MAJOR_CAPS" 1 440
create_device /dev/nvidia-caps/nvidia-cap2 "$MAJOR_CAPS" 2 440
create_device /dev/nvidia-caps/nvidia-cap3 "$MAJOR_CAPS" 3 440
create_device /dev/nvidia-caps/nvidia-cap4 "$MAJOR_CAPS" 4 440
