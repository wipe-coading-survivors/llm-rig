# base: scratch (empty image, holds driver .run archive)
FROM scratch

ARG DRIVER_VER
ARG DRIVER_URL
ARG REDIST_SIZE
ARG REDIST_ETAG

ADD $DRIVER_URL /installer.run

LABEL \
    com.nvidia/driver.version="$DRIVER_VER" \
    com.nvidia/driver.redist.url="$DRIVER_URL" \
    com.nvidia/driver.redist.size="$REDIST_SIZE" \
    com.nvidia/driver.redist.etag="$REDIST_ETAG"
