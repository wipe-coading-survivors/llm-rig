ARG BASE_IMAGE
ARG NVIDIA_XORG_IMAGE
ARG CUDA_REPO_BASE

# nvidia-drv-libs: nvidia-xorg (driver user-space libs), injected by Makefile
FROM ${NVIDIA_XORG_IMAGE} as nvidia-drv-libs

# base: nvidia-base (fedora-minimal + dnf), injected by Makefile
FROM ${BASE_IMAGE}

ARG NVIDIA_XORG_IMAGE_ID
ARG CUDA_REPO_BASE
ARG CUDA_PKG_SERIES
ARG CUDA_DEVEL_SET

RUN \
  --mount=type=bind,from=nvidia-drv-libs,source=/,target=/mnt/drv-libs \
  set -euxo pipefail ; \
  curl -SLo /etc/yum.repos.d/cuda-fedora44.repo $CUDA_REPO_BASE/cuda-fedora44.repo ; \
  cp -arv /mnt/drv-libs/opt/nvidia/ /opt/nvidia/ && \
  cp -av /mnt/drv-libs/usr/lib64/libcuda* /usr/lib64/ && \
  cp -av /mnt/drv-libs/usr/lib64/libnvidia* /usr/lib64/ && \
  ln -s /opt/nvidia/10_local.conf /etc/ld.so.conf.d/ && \
  dnf install -y --setopt=install_weak_deps=False $CUDA_DEVEL_SET \
  && \
  dnf clean all && \
  ldconfig && \
  rpm -qa | grep -- "-${CUDA_PKG_SERIES}-" | sort > /usr/local/cuda-installed.txt
