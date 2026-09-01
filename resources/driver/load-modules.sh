#!/bin/bash

rmmod nouveau 2> /dev/null

depmod -a

MODULES="nvidia-uvm"

# The 30-series (Ampere) frequently drops the connection and throws RmInitAdapter failed on newer kernels
# due to buggy GSP firmware behavior. Force the driver to use older, stable initialization code instead: 
# ```bash
#  echo "options nvidia NVreg_EnableGpuFirmware=0" | sudo tee /etc/modprobe.d/nvidia-gsp.conf
# ```
modprobe nvidia NVreg_EnableGpuFirmware=0

for m in $MODULES; do
    modprobe $m
done
