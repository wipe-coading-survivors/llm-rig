# base: scratch (empty image, holds CUDA .run archive)
FROM scratch

ARG CUDA_VER
ARG CUDA_URL
ARG REDIST_SIZE
ARG REDIST_ETAG

ADD $CUDA_URL /installer.sh

LABEL \
    com.nvidia/cuda.version="$CUDA_VER" \
    com.nvidia/cuda.redist.url="$CUDA_URL" \
    com.nvidia/cuda.redist.size="$REDIST_SIZE" \
    com.nvidia/cuda.redist.etag="$REDIST_ETAG"
