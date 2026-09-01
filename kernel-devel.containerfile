ARG BASE_IMAGE
ARG KERNEL_REDIST_IMAGE

# rpms: kernel-redist (kernel RPMs pinned to KERNEL_VERSION), injected by Makefile
FROM ${KERNEL_REDIST_IMAGE} as rpms

# base: nvidia-base (fedora-minimal + dnf), injected by Makefile
FROM ${BASE_IMAGE}

ARG KVER
ARG KERNEL_REDIST_IMAGE_ID

RUN \
  set -euxo pipefail; \
  dnf install -y \
    bison \
    dracut \
    elfutils-libelf-devel \
    flex \
    gcc-c++ \
    hostname \
    nvidia-gpu-firmware \
    openssl-devel \
    perl-interpreter \
    xz \
  && \
  dnf clean all

RUN --mount=type=bind,from=rpms,source=/,target=/mnt/rpms \
  set -euxo pipefail; \
  dnf install -y /mnt/rpms/kernel-*.rpm

RUN \
  set -euxo pipefail; \
  rpm -q \
    "kernel-core-${KVER}" \
    "kernel-modules-core-${KVER}" \
    "kernel-devel-${KVER}" ; \
  test -f /usr/src/kernels/${KVER}/.config
