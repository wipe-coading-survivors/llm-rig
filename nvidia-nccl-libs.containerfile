ARG NCCL_DEVEL_IMAGE
ARG BASE_IMAGE

# nccl-src: nccl-devel (NCCL built for our CUDA), injected by Makefile
FROM ${NCCL_DEVEL_IMAGE} as nccl-src

# base: nvidia-cuda-libs (runtime image), injected by Makefile
FROM ${BASE_IMAGE}

ARG CUDA_VER
ARG NCCL_DEVEL_IMAGE_ID

RUN \
  --mount=type=bind,from=nccl-src,source=/usr/local/cuda-${CUDA_VER},target=/mnt/nccl \
  set -euxo pipefail ; \
  cp -aP /mnt/nccl/lib64/libnccl.so* /usr/local/cuda-${CUDA_VER}/lib64/ && \
  ldconfig && \
  ldconfig -p | grep -q libnccl
