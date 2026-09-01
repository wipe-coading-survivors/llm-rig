#
# to work it correctly the file /usr/lib/firmware/nvidia/<driver_version>/<gsp_name>.bin must be present
# for example: /usr/lib/firmware/nvidia/610.43.03/gsp_ga10x.bin
# this file is a part of the nvidia drivers distribution
#
# The 30-series (Ampere) frequently drops the connection and throws RmInitAdapter failed on newer kernels
# due to buggy GSP firmware behavior. Force the driver to use older, stable initialization code instead: 
# ```bash
#  echo "options nvidia NVreg_EnableGpuFirmware=0" | sudo tee /etc/modprobe.d/nvidia-gsp.conf
# ```
#

ARG BASE_IMAGE
ARG KERNEL_DEVEL_IMAGE
ARG KERNEL_VERSION
# builder: kernel-devel (kernel headers + build tools), injected by Makefile
FROM ${KERNEL_DEVEL_IMAGE} as builder

WORKDIR /usr/src/open-gpu-kernel-modules/

COPY . .

RUN \
  set -euxo pipefail ; \
  kver=${KERNEL_VERSION:-$(uname -r)} && \
  mkdir -p /lib/modules/$kver && \
  ln -s /usr/src/kernels/$kver /lib/modules/$kver/build && \
  make modules -j$(nproc) KERNEL_UNAME=$kver && \
  make modules_install -j$(nproc) KERNEL_UNAME=$kver && \
  depmod -a $kver && \
  make clean KERNEL_UNAME=$kver -j $(nproc)

ARG BASE_IMAGE
# base: nvidia-base (fedora-minimal + dnf), injected by Makefile
FROM ${BASE_IMAGE}

RUN \
  dnf install -y \
    hostname \
    kmod \
    less \
    nvidia-gpu-firmware \
  && \
  dnf clean all

COPY --from=builder \
  /usr/lib/modules/${KERNEL_VERSION}/System.map \
  /usr/lib/modules/${KERNEL_VERSION}/config \
  /usr/lib/modules/${KERNEL_VERSION}/modules.* \
  /usr/lib/modules/${KERNEL_VERSION}/symvers.xz \
  /usr/lib/modules/${KERNEL_VERSION}/

COPY --from=builder \
  /usr/lib/modules/${KERNEL_VERSION}/kernel/drivers/video/nvidia* \
  /usr/lib/modules/${KERNEL_VERSION}/kernel/drivers/video/

WORKDIR /usr/lib/modules/${KERNEL_VERSION}
