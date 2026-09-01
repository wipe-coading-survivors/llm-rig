ARG BASE_IMAGE
ARG CUDA_VER
ARG NVIDIA_XORG_IMAGE
ARG CUDA_REDIST_IMAGE

# nvidia-drv-libs: nvidia-xorg (driver user-space libs), injected by Makefile
FROM ${NVIDIA_XORG_IMAGE} as nvidia-drv-libs

# cuda-redist: nvidia-redist-cuda (CUDA toolkit .run archive), injected by Makefile
FROM ${CUDA_REDIST_IMAGE} as cuda-redist

# base: nvidia-base (fedora-minimal + dnf), injected by Makefile
FROM ${BASE_IMAGE}

ARG CUDA_VER
ARG NVIDIA_XORG_IMAGE_ID
ARG CUDA_REDIST_IMAGE_ID

#COPY --from=libs /opt/nvidia/ /opt/nvidia/
#COPY --from=libs /usr/lib64/libcuda* /usr/lib64/
#COPY --from=libs /usr/lib64/libnvidia* /usr/lib64/

RUN \
  --mount=type=bind,from=cuda-redist,source=/,target=/mnt/cuda-redist \
  --mount=type=bind,from=nvidia-drv-libs,source=/,target=/mnt/drv-libs \
  set -euxo pipefail ; \
#  dnf install -y \
#    gzip \ 
#    tar \
#  && \
  cp -arv /mnt/drv-libs/opt/nvidia/ /opt/nvidia/ && \
  cp -av /mnt/drv-libs/usr/lib64/libcuda* /usr/lib64/ && \
  cp -av /mnt/drv-libs/usr/lib64/libnvidia* /usr/lib64/ && \
  bash /mnt/cuda-redist/installer.sh \
    --no-drm \
    --no-man-page \
    --override \
    --toolkitpath=/opt/cuda-${CUDA_VER} \
    --toolkit \
    --silent \
  && \
  ln -s /opt/cuda{-${CUDA_VER},} && \
  echo /opt/cuda/lib64 > /opt/cuda/20_local.conf && \
  ln -s /opt/nvidia/10_local.conf /etc/ld.so.conf.d/ && \
  ln -s /opt/cuda/20_local.conf /etc/ld.so.conf.d/ && \
  ldconfig
