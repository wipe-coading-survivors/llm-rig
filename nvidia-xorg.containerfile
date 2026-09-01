ARG BASE_IMAGE
ARG DRIVER_REDIST_IMAGE
# redist: nvidia-redist-drv (NVIDIA driver .run archive), injected by Makefile
FROM ${DRIVER_REDIST_IMAGE} as redist

# base: nvidia-base (fedora-minimal + dnf), injected by Makefile
FROM ${BASE_IMAGE}

ARG DRIVER_REDIST_IMAGE_ID

RUN \
  dnf install -y \
    gtk3 \
    libglvnd-devel \
    vulkan-{loader,tools} \
    xorg-x11-server-Xorg \
  && \
  dnf clean all

#COPY --from=redist --chmod=755 /installer.run /tmp/installer.run

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

COPY driver/NEC-EA244WMi.edid /etc/X11
COPY driver/etc/ /etc/
COPY driver/set-card-properties.sh /
