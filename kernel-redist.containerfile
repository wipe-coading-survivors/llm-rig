# base: scratch (empty image, holds the kernel RPMs)
FROM scratch

ARG KVER
ARG CORE_URL
ARG CORE_SIZE
ARG CORE_MTIME
ARG MODCORE_URL
ARG MODCORE_SIZE
ARG MODCORE_MTIME
ARG DEVEL_URL
ARG DEVEL_SIZE
ARG DEVEL_MTIME
ARG HEADERS_URL
ARG HEADERS_SIZE
ARG HEADERS_MTIME

ADD $CORE_URL /kernel-core.rpm
ADD $MODCORE_URL /kernel-modules-core.rpm
ADD $DEVEL_URL /kernel-devel.rpm
ADD $HEADERS_URL /kernel-headers.rpm

LABEL \
    com.llm-rig/kernel.version="$KVER" \
    com.llm-rig/kernel.redist.core.url="$CORE_URL" \
    com.llm-rig/kernel.redist.core.size="$CORE_SIZE" \
    com.llm-rig/kernel.redist.core.mtime="$CORE_MTIME" \
    com.llm-rig/kernel.redist.modules-core.url="$MODCORE_URL" \
    com.llm-rig/kernel.redist.modules-core.size="$MODCORE_SIZE" \
    com.llm-rig/kernel.redist.modules-core.mtime="$MODCORE_MTIME" \
    com.llm-rig/kernel.redist.devel.url="$DEVEL_URL" \
    com.llm-rig/kernel.redist.devel.size="$DEVEL_SIZE" \
    com.llm-rig/kernel.redist.devel.mtime="$DEVEL_MTIME" \
    com.llm-rig/kernel.redist.headers.url="$HEADERS_URL" \
    com.llm-rig/kernel.redist.headers.size="$HEADERS_SIZE" \
    com.llm-rig/kernel.redist.headers.mtime="$HEADERS_MTIME"
