ARG \
  BASE_IMAGE \
  CUDA_DEVEL_IMAGE

# builder: nvidia-nccl-devel (our NCCL devel image), injected by Makefile
FROM ${CUDA_DEVEL_IMAGE} AS builder

ARG CUDA_ARCH
ARG GCC_VER

RUN \
  dnf install -y \
    cmake \
    gcc \
    gcc${GCC_VER}{,-c++} \
    git \
    ninja-build \
  && \
  dnf clean all

WORKDIR /llama

COPY . . 

ARG NVCC=/opt/cuda/bin/nvcc

#    -DGGML_NATIVE=OFF \
RUN \
  cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=/usr/bin/gcc-${GCC_VER} \
    -DCMAKE_CXX_COMPILER=/usr/bin/g++-${GCC_VER} \
    -DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCH} \
    -DCMAKE_CUDA_COMPILER=${NVCC} \
    -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++-${GCC_VER} \
    -DGGML_CUDA=ON \
    -DGGML_CUDA_FORCE_MMQ=ON \
    -DGGML_CUDA_NCCL=ON \
    -DNCCL_ROOT=/opt/cuda \
    -GNinja \
  && \
  cmake --build build --parallel $(nproc)
  #--target llama-server

# base: nvidia-nccl-libs (our NCCL runtime image), injected by Makefile
FROM ${BASE_IMAGE}

ARG LLAMA_CPP_REF
ARG LLAMA_CPP_REPO
ARG LLAMA_CPP_SHA

LABEL \
    com.llm-rig/llama-cpp.ref="$LLAMA_CPP_REF" \
    com.llm-rig/llama-cpp.repo="$LLAMA_CPP_REPO" \
    com.llm-rig/llama-cpp.sha="$LLAMA_CPP_SHA"

WORKDIR /app

COPY --from=builder /llama/build/bin/ /app/

EXPOSE 8080

ENTRYPOINT ["/app/llama-server"]
