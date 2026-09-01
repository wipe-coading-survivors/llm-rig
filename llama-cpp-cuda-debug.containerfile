ARG \
  BASE_IMAGE \
  LLAMA_IMAGE

# builder: llama-cpp-cuda (our prod llama build), injected by Makefile
FROM ${LLAMA_IMAGE} AS builder

# base: nvidia-nccl-devel (our NCCL devel image, CUDA debug tooling), injected by Makefile
FROM ${BASE_IMAGE}

WORKDIR /

RUN \
  rm -rf /app

COPY --from=builder /app /app/

WORKDIR /app

EXPOSE 8080
