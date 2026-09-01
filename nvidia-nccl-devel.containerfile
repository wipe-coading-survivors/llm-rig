ARG CUDA_DEVEL_IMAGE

# base: nvidia-cuda-devel (our CUDA devel image), injected by Makefile
FROM ${CUDA_DEVEL_IMAGE}

ARG CUDA_VER
ARG NVCC=/usr/local/cuda/bin/nvcc
ARG CUDA_ARCH
ARG GCC_VER

RUN \
  dnf install -y \
    gcc${GCC_VER}{,-c++} \
    git \
    make \
    python3 \
    which

WORKDIR /app

COPY . .

RUN \
  set -euxo pipefail ; \
  cuda_home=$(dirname $(dirname ${NVCC})) && \
  make -j$(nproc) src.build \
    CUDA_HOME=${cuda_home} \
    CXX=g++-${GCC_VER} \
    NVCC_GENCODE="-gencode=arch=compute_${CUDA_ARCH},code=sm_${CUDA_ARCH}" && \
  cp -aP build/lib/libnccl* /usr/local/cuda-${CUDA_VER}/lib64/ && \
  cp -a build/include/nccl.h build/include/nccl_device.h /usr/local/cuda-${CUDA_VER}/include/ && \
  cp -a build/include/nccl_device /usr/local/cuda-${CUDA_VER}/include/ && \
  cp -a build/bin/ncclras build/bin/ncclparam /usr/local/cuda-${CUDA_VER}/bin/ && \
  ldconfig && \
  ldconfig -p | grep -q libnccl
