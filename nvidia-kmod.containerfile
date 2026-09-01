#
# The 30-series (Ampere) frequently drops the connection and throws RmInitAdapter failed on newer kernels
# due to buggy GSP firmware behavior. Force the driver to use older, stable initialization code instead: 
# ```bash
#  echo "options nvidia NVreg_EnableGpuFirmware=0" | sudo tee /etc/modprobe.d/nvidia-gsp.conf
# ```

ARG BASE_IMAGE
ARG KERNEL_DEVEL_IMAGE
ARG KERNEL_VERSION
ARG DRIVER_REDIST_IMAGE

# redist: nvidia-redist-drv (NVIDIA driver .run archive), injected by Makefile
FROM ${DRIVER_REDIST_IMAGE} as redist

# builder: kernel-devel (kernel headers + build tools), injected by Makefile
FROM ${KERNEL_DEVEL_IMAGE} as builder
ARG KERNEL_VERSION
ARG DRIVER_REDIST_IMAGE_ID

#COPY --from=redist --chmod=755 /installer.run /tmp

RUN --mount=type=bind,from=redist,source=/,target=/mnt/redist \
  set -euxo pipefail ; \
  dnf install -y dwarves ; \
  kver=${KERNEL_VERSION:-$(uname -r)} ; \
  if [ ! -f /usr/src/kernels/$kver/.config ] ; then \
    echo "ERROR: kernel-devel image does not contain kernel $kver (mislabeled?)" >&2 ; \
    exit 1 ; \
  fi ; \
  mkdir -p /lib/modules/$kver && \
  ln -s /usr/src/kernels/$kver /lib/modules/$kver/build && \
  bash /mnt/redist/installer.run \
    -x \
    --target /tmp/nvidia-driver \
  && \
  cd /tmp/nvidia-driver/kernel && \
  make modules -j $(nproc) KERNEL_UNAME=$kver && \
  make modules_install -j $(nproc) KERNEL_UNAME=$kver && \
  cd /usr/lib/modules/$kver && \
  for m in kernel/drivers/video/nvidia* ; do \
    deps=$(modinfo $m | awk -F: '/^depends/ { print $2; }' | tr -d [:space:] | sed 's/,/ /g') && \
    for d in $deps ; do \
      echo $d >> /tmp/module-deps.txt ; \
    done ; \
  done ; \
  cat /tmp/module-deps.txt | sort -u > NVIDIA_MODULE_DEPS && \
  cat NVIDIA_MODULE_DEPS

ARG BASE_IMAGE
# base: nvidia-base (fedora-minimal + dnf), injected by Makefile
FROM ${BASE_IMAGE}

RUN \
  dnf install -y \
    kmod \
    less \
  && \
  dnf clean all


ARG KERNEL_VERSION
ARG KERNEL_DEVEL_IMAGE_ID
ARG DRIVER_REDIST_IMAGE_ID

#COPY --from=builder \
#    /usr/lib/modules/${KERNEL_VERSION}/System.map \
#    /usr/lib/modules/${KERNEL_VERSION}/config \
#    /usr/lib/modules/${KERNEL_VERSION}/modules.* \
#    /usr/lib/modules/${KERNEL_VERSION}/symvers.xz \
#    /usr/lib/modules/${KERNEL_VERSION}/
#
#COPY --from=builder \
#    /usr/lib/modules/${KERNEL_VERSION}/kernel/drivers/video/nvidia* \
#    /usr/lib/modules/${KERNEL_VERSION}/kernel/drivers/video/

WORKDIR /usr/lib/modules/${KERNEL_VERSION}

RUN --mount=type=bind,from=builder,source=/usr/lib/modules,target=/mnt/ \
  set -euxo pipefail ; \
  kver=${KERNEL_VERSION:-$(uname -r)} ; \
  tdir=/usr/lib/modules/${kver} ; \
  mkdir -p /usr/lib/modules/${kver} && \
  cd /mnt/$kver && \
  while read m ; do \
    fp=$(find . -name "${m}.ko*" -print) ; \
    dir1=$(dirname $fp) ; \
    mkdir -p ${tdir}/$dir1 ; \
    cp -v $fp ${tdir}/$dir1 ; \
  done < NVIDIA_MODULE_DEPS ; \
  cp -v config modules.* symvers.* System.map ${tdir} && \
  cp -v kernel/drivers/video/nvidia* ${tdir}/kernel/drivers/video/

COPY driver/create-devices.sh driver/load-modules.sh /
