ARG BASE_IMAGE
ARG CUDA_VER
ARG CUDA_DEVEL_IMAGE
ARG NVIDIA_XORG_IMAGE

# cuda: nvidia-cuda-devel (CUDA toolkit), injected by Makefile
FROM ${CUDA_DEVEL_IMAGE} as cuda

# libs: nvidia-xorg (driver user-space libs), injected by Makefile
FROM ${NVIDIA_XORG_IMAGE} as libs

# base: nvidia-base (fedora-minimal + dnf), injected by Makefile
FROM ${BASE_IMAGE}

ARG CUDA_VER
ARG NVIDIA_XORG_IMAGE_ID
ARG CUDA_DEVEL_IMAGE_ID

#COPY --from=libs /opt/nvidia/ /opt/nvidia/
#COPY --from=libs /usr/lib64/libcuda* /usr/lib64/
#COPY --from=libs /usr/lib64/libnvidia* /usr/lib64/

#COPY --from=cuda /opt/ /opt/

RUN --mount=type=bind,from=libs,source=/,target=/mnt/libs \
    --mount=type=bind,from=cuda,source=/,target=/mnt/cuda \
  set -exuo pipefail ; \
  tar -C /mnt/libs -c opt/nvidia | tar -C / -xv && \
  tar -C /mnt/libs/usr/lib64 -c $(cd /mnt/libs/usr/lib64 ; ls lib{cuda,nvidia}*) | tar -C /usr/lib64 -xv && \
  mkdir -p /opt/cuda-${CUDA_VER}/lib64 && \
  tar -C /mnt/cuda/opt/cuda-${CUDA_VER}/targets/x86_64-linux/lib -c . | tar -C /opt/cuda-${CUDA_VER}/lib64 -xv && \
  ln -s /opt/cuda{-${CUDA_VER},} && \
  echo /opt/cuda/lib64 > /opt/cuda/20_local.conf && \
  ln -s /opt/nvidia/10_local.conf /etc/ld.so.conf.d/ && \
  ln -s /opt/cuda/20_local.conf /etc/ld.so.conf.d/ && \
  ldconfig && \
  dnf install -y \
    numactl \
  && \
  dnf clean all
