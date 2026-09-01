ARG LACT_IMAGE
# base: nvidia-lact (driver utilities + nvidia-smi + LACT RPM), injected
# by Makefile
FROM ${LACT_IMAGE}

RUN dnf install -y python3 && dnf clean all

COPY driver/lact-autoswitch.py /lact-autoswitch.py
RUN chmod 755 /lact-autoswitch.py
