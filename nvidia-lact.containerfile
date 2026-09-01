ARG BASE_IMAGE
ARG DRIVER_REDIST_IMAGE
ARG LACT_REDIST_IMAGE
# redist: nvidia-redist-drv (NVIDIA driver .run archive), injected by Makefile
FROM ${DRIVER_REDIST_IMAGE} as redist

# lact artifact: lact-redist (LACT headless RPM), injected by Makefile
FROM ${LACT_REDIST_IMAGE} as lact

# base: nvidia-base (fedora-minimal + dnf), injected by Makefile
FROM ${BASE_IMAGE}

ARG DRIVER_REDIST_IMAGE_ID
ARG LACT_REDIST_IMAGE_ID

RUN --mount=type=bind,from=redist,source=/,target=/mnt/ \
    bash /mnt/installer.run \
      --utility-prefix=/opt/nvidia \
      --log-file-name=/opt/nvidia/installer.log \
      --no-backup \
      --no-install-compat32-libs \
      --no-kernel-module \
      --no-nouveau-check \
      --no-systemd \
      --no-wine-files \
      --no-x-check \
      --skip-depmod \
      -q \
      --skip-module-unload \
      --ui=none \
    && \
    echo /opt/nvidia/lib64 > /opt/nvidia/10_local.conf && \
    ln -s /opt/nvidia/10_local.conf /etc/ld.so.conf.d/ && \
    ldconfig

RUN --mount=type=bind,from=lact,source=/lact-headless.rpm,target=/tmp/lact-headless.rpm \
    dnf install -y /tmp/lact-headless.rpm \
    && dnf clean all

RUN lact cli --version

COPY driver/lact/lact.sh /lact.sh
RUN chmod 755 /lact.sh

# nvidia-smi and driver utilities on the default PATH (user decision 28.08)
ENV PATH=$PATH:/opt/nvidia/bin
