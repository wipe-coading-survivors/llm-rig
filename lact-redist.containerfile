# base: scratch (empty image, holds the LACT headless RPM)
FROM scratch

ARG LACT_VER
ARG LACT_URL
ARG LACT_SIZE
ARG LACT_ETAG

ADD $LACT_URL /lact-headless.rpm

LABEL \
    com.nvidia/lact.version="$LACT_VER" \
    com.nvidia/lact.redist.url="$LACT_URL" \
    com.nvidia/lact.redist.size="$LACT_SIZE" \
    com.nvidia/lact.redist.etag="$LACT_ETAG"
