#!/bin/bash
# Production llama-server (llama-cpp-cuda) — manual fallback for the
# llama-cpp.service unit (the unit is the canonical prod command).
# Named container + rm -f before run mirror the unit ExecStartPre
# (reproducible restart, equivalent to the unit also for an existing
# container). No GPU pin: thermal balancing is covered by
# LACT per-card OC.
CRE=podman
[ -f /run/.containerenv ] && CRE=podman-remote
$CRE rm -f llama-cpp
exec $CRE run -d --name llama-cpp \
  --device /dev/nvidia0 --device /dev/nvidia1 --device /dev/nvidia2 \
  --device /dev/nvidia3 --device /dev/nvidia4 \
  --security-opt label=disable --privileged --shm-size=64g \
  -v /var/local/llm/gguf-models:/models \
  -v /etc/llama:/root/llama:ro \
  -p 8080:8080 \
  -e LLAMA_LOG_TIMESTAMPS=1 \
  localhost/llama-cpp-cuda:13.2 --port 8080 --host 0.0.0.0 \
  --models-preset /root/llama/llama.ini
