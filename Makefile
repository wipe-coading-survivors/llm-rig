#
#
#

-include local.mk
BASE_IMAGE_TAG	?= 44
BASE_IMAGE	?= registry.fedoraproject.org/fedora-minimal:$(BASE_IMAGE_TAG)

CRE		?= $(shell echo -n podman ; [ -e /run/.containerenv ] && echo -remote)
HOST_ROOT	?= $(shell [ -e /run/.containerenv ] && echo /run/host)
SYSTEMDCTL	?= $(if $(HOST_ROOT),chroot $(HOST_ROOT) /usr/bin/systemctl,systemctl)

BUILDER_HOST	?= $(shell h=$$(hostname); h=$${h/toolbx/$$(awk -F\" '/name=/ { print $$2; }' /run/.containerenv)}; echo $$h)

#KVER		?= 6.4.7-200.fc38.x86_64
KVER		?= $(shell uname -r)
NVIDIA_DRV_VER	?= 610.43.03
NVIDIA_CUDA_VER	?= 13.3
NVIDIA_DRV_RUN_URL = https://download.nvidia.com/XFree86/Linux-x86_64/$(NVIDIA_DRV_VER)/NVIDIA-Linux-x86_64-$(NVIDIA_DRV_VER)-no-compat32.run
LACT_VER	?= v0.10.0
LACT_URL	?= https://github.com/ilya-zlobintsev/LACT/releases/download/$(LACT_VER)/lact-headless-0.10.0-0.x86_64.fedora-44.rpm
CUDA_REPO_BASE	?= https://developer.download.nvidia.com/compute/cuda/repos/fedora44/x86_64
CUDA_PKG_SERIES	?= $(subst .,-,$(NVIDIA_CUDA_VER))
CUDA_DEVEL_SET	?= cuda-minimal-build-$(CUDA_PKG_SERIES) cuda-driver-devel-$(CUDA_PKG_SERIES) cuda-sanitizer-$(CUDA_PKG_SERIES) libcublas-devel-$(CUDA_PKG_SERIES) libcufft-devel-$(CUDA_PKG_SERIES) libcurand-devel-$(CUDA_PKG_SERIES) libcusolver-devel-$(CUDA_PKG_SERIES) libcusparse-devel-$(CUDA_PKG_SERIES) libnvjitlink-devel-$(CUDA_PKG_SERIES)
CUDA_RUNTIME_SET ?= cuda-cudart-$(CUDA_PKG_SERIES) libcublas-$(CUDA_PKG_SERIES) libcufft-$(CUDA_PKG_SERIES) libcurand-$(CUDA_PKG_SERIES) libcusolver-$(CUDA_PKG_SERIES) libcusparse-$(CUDA_PKG_SERIES) libnvfatbin-$(CUDA_PKG_SERIES) libnvjitlink-$(CUDA_PKG_SERIES)

NVIDIA_OSS_KMOD	= open-gpu-kernel-modules
NVIDIA_OSS_KMOD_URL ?= https://github.com/NVIDIA/open-gpu-kernel-modules.git

LLAMA_CPP       = llama-cpp
LLAMA_CPP_REF	?= master
LLAMA_CPP_REPO	?= https://github.com/ggml-org/llama.cpp.git

NCCL        = nccl
NCCL_REF    ?= v2.31.2-1
NCCL_REPO   ?= https://github.com/NVIDIA/nccl.git

CUDA_ARCH	?= 86
GCC_VER		?= 15
NVCC		?= /usr/local/cuda/bin/nvcc
LLAMA_HOST ?= 127.0.0.1
LLM_NFS_SERVER ?= 127.0.0.1
LLAMA_PORT ?= 8080
LLAMA_URL = http://$(LLAMA_HOST):$(LLAMA_PORT)
LLAMA_MODEL ?= default
LLAMA_KEYS_FILE ?= /etc/llama/llama-cpp-keys.txt
OPENCODE_CONFIG ?=

# image references: single source of truth for names/tags
NVIDIA_BASE_IMAGE      = nvidia-base:$(BASE_IMAGE_TAG)
KERNEL_DEVEL_IMAGE     = kernel-devel:$(KVER)
KERNEL_REDIST_IMAGE    = kernel-redist:$(KVER)
NVIDIA_REDIST_DRV_IMG  = nvidia-redist-drv:$(NVIDIA_DRV_VER)
NVIDIA_XORG_IMAGE      = nvidia-xorg:$(NVIDIA_DRV_VER)
LACT_REDIST_IMAGE = lact-redist:$(LACT_VER)
NVIDIA_LACT_IMAGE = nvidia-lact-$(NVIDIA_DRV_VER):$(LACT_VER)
NVIDIA_LACT_AUTOSWITCH_IMAGE = nvidia-lact-autoswitch-$(NVIDIA_DRV_VER):$(LACT_VER)
NVIDIA_CUDA_DEVEL_IMG  = nvidia-cuda-devel:$(NVIDIA_CUDA_VER)
NVIDIA_CUDA_LIBS_IMG   = nvidia-cuda-libs:$(NVIDIA_CUDA_VER)
NCCL_DEVEL_IMAGE     = nvidia-nccl-devel-cuda-$(NVIDIA_CUDA_VER):$(NCCL_REF)
NCCL_LIBS_IMAGE      = nvidia-nccl-libs-cuda-$(NVIDIA_CUDA_VER):$(NCCL_REF)
LLAMA_CPP_REPO_DEFAULT = https://github.com/ggml-org/llama.cpp.git
_llama_default = $(and $(filter master,$(LLAMA_CPP_REF)), $(filter $(LLAMA_CPP_REPO_DEFAULT),$(LLAMA_CPP_REPO)))
LLAMA_CPP_VARIANT = $(if $(_llama_default),,$(subst /,-,$(LLAMA_CPP_REF)))
LLAMA_CPP_NAME = llama-cpp$(if $(LLAMA_CPP_VARIANT),-$(LLAMA_CPP_VARIANT))-cuda
LLAMA_CPP_IMAGE = $(LLAMA_CPP_NAME):$(NVIDIA_CUDA_VER)
LLAMA_DEBUG_IMAGE = $(LLAMA_CPP_NAME)-debug:$(NVIDIA_CUDA_VER)
NVIDIA_KMOD_IMAGE   = nvidia-kmod-$(NVIDIA_DRV_VER):$(KVER)

KOJI_BASE_URL ?= https://kojipkgs.fedoraproject.org

clean:
	$(CRE) images | awk '/^<none>/ { print $$3; }' | xargs $(CRE) rmi || true
	rm -rf empty
	$(CURDIR)/scripts/safe-rm --under $(CURDIR) $(CURDIR)/$(NVIDIA_OSS_KMOD)

_empty:
	mkdir -p empty
	touch empty/1.txt

nvidia-base: _empty
	$(CRE) build \
	  --build-arg REPO_BASE_URL=$(REPO_BASE_URL) \
	  --build-arg BASE_IMAGE=$(BASE_IMAGE) \
	  -f $@.containerfile \
	  -t $(NVIDIA_BASE_IMAGE) \
	  empty

kernel-devel: nvidia-base kernel-redist
	rid=$$($(CRE) inspect --format "{{.Id}}" $(KERNEL_REDIST_IMAGE)) || exit 1 ; \
	  $(CRE) build \
	  --build-arg BASE_IMAGE=$(NVIDIA_BASE_IMAGE) \
	  --build-arg KERNEL_REDIST_IMAGE=$(KERNEL_REDIST_IMAGE) \
	  --build-arg KERNEL_REDIST_IMAGE_ID=$$rid \
	  --build-arg KVER=$(KVER) \
	  -f $@.containerfile \
	  -t $(KERNEL_DEVEL_IMAGE) \
	  empty

kernel-redist: _empty
	@status=$$(CRE=$(CRE) scripts/kernel-check.sh $(if $(FORCE),--force) $(KERNEL_REDIST_IMAGE) $(KOJI_BASE_URL) $(KVER)) || { \
	  if [ -z "$(FORCE)" ] && $(CRE) image exists $(KERNEL_REDIST_IMAGE) ; then \
	  echo "WARN: remote unreachable, using existing $(KERNEL_REDIST_IMAGE)" ; \
	  exit 0 ; \
	  fi ; \
	  echo "ERROR: remote unreachable (no size/last-modified for LABELs) and no usable local image $(KERNEL_REDIST_IMAGE)" >&2 ; \
	  exit 1 ; \
	  } ; \
	  case $$status in \
	  up-to-date) \
	  echo "$(KERNEL_REDIST_IMAGE) up to date" ; \
	  exit 0 ;; \
	  esac ; \
	  set -- $$status ; shift ; \
	  $(CRE) build \
	  --build-arg KVER=$(KVER) \
	  --build-arg CORE_URL=$$1 --build-arg CORE_SIZE=$$2 --build-arg CORE_MTIME=$$3 \
	  --build-arg MODCORE_URL=$$4 --build-arg MODCORE_SIZE=$$5 --build-arg MODCORE_MTIME=$$6 \
	  --build-arg DEVEL_URL=$$7 --build-arg DEVEL_SIZE=$$8 --build-arg DEVEL_MTIME=$$9 \
	  --build-arg HEADERS_URL=$${10} --build-arg HEADERS_SIZE=$${11} --build-arg HEADERS_MTIME=$${12} \
	  -f $@.containerfile \
	  -t $(KERNEL_REDIST_IMAGE) \
	  empty

kmod-oss: kernel-devel nvidia-base
	if [ -d $(NVIDIA_OSS_KMOD) ] ; then \
	  pushd $(NVIDIA_OSS_KMOD) && \
	  git fetch origin $(NVIDIA_DRV_VER) && \
	  popd || exit 1 ; \
	  else \
	  git clone -o origin $(NVIDIA_OSS_KMOD_URL) $(NVIDIA_OSS_KMOD) || exit 1; \
	  pushd $(NVIDIA_OSS_KMOD) && \
	  git fetch origin $(NVIDIA_DRV_VER) && \
	  popd || exit 1 ; \
	  fi ; \
	  pushd $(NVIDIA_OSS_KMOD) && \
	  git checkout -f FETCH_HEAD && \
	  popd || exit 1 ; \
	  printf '**/.git\n' > $(NVIDIA_OSS_KMOD)/.containerignore ; \
	  $(CRE) build \
	  --build-arg KERNEL_DEVEL_IMAGE=$(KERNEL_DEVEL_IMAGE) \
	  --build-arg BASE_IMAGE=$(NVIDIA_BASE_IMAGE) \
	  --env HOSTNAME=$(BUILDER_HOST) \
	  --env KERNEL_VERSION=$(KVER) \
	  -f nvidia-$@.containerfile \
	  -t nvidia-$@-$(NVIDIA_DRV_VER):$(KVER) \
	  $(NVIDIA_OSS_KMOD)

kmod: kernel-devel nvidia-redist-drv nvidia-base
	kdid=$$($(CRE) inspect --format "{{.Id}}" $(KERNEL_DEVEL_IMAGE)) || exit 1 ; \
	  did=$$($(CRE) inspect --format "{{.Id}}" $(NVIDIA_REDIST_DRV_IMG)) || exit 1 ; \
	  $(CRE) build \
	  --build-arg BASE_IMAGE=$(NVIDIA_BASE_IMAGE) \
	  --build-arg KERNEL_DEVEL_IMAGE=$(KERNEL_DEVEL_IMAGE) \
	  --build-arg DRIVER_REDIST_IMAGE=$(NVIDIA_REDIST_DRV_IMG) \
	  --build-arg KERNEL_DEVEL_IMAGE_ID=$$kdid \
	  --build-arg DRIVER_REDIST_IMAGE_ID=$$did \
	  --build-arg KERNEL_VERSION=$(KVER) \
	  --env HOSTNAME=$(BUILDER_HOST) \
	  -f nvidia-$@.containerfile \
	  -t $(NVIDIA_KMOD_IMAGE) \
	  resources

nvidia-redist-drv: _empty
	@status=$$(CRE=$(CRE) scripts/redist-check.sh $(if $(FORCE),--force) $(NVIDIA_DRV_RUN_URL) $(NVIDIA_REDIST_DRV_IMG) com.nvidia/driver.redist) || { \
	  if [ -z "$(FORCE)" ] && $(CRE) image exists $(NVIDIA_REDIST_DRV_IMG) ; then \
	  echo "WARN: remote unreachable, using existing $(NVIDIA_REDIST_DRV_IMG)" ; \
	  exit 0 ; \
	  fi ; \
	  echo "ERROR: remote unreachable (no size/etag for LABELs) and no usable local image $(NVIDIA_REDIST_DRV_IMG)" >&2 ; \
	  exit 1 ; \
	  } ; \
	  case $$status in \
	  up-to-date) \
	  echo "$(NVIDIA_REDIST_DRV_IMG) up to date" ; \
	  exit 0 ;; \
	  esac ; \
	  set -- $$status ; shift ; \
	  $(CRE) build \
	  --build-arg DRIVER_VER=$(NVIDIA_DRV_VER) \
	  --build-arg DRIVER_URL=$(NVIDIA_DRV_RUN_URL) \
	  --build-arg REDIST_SIZE=$$1 \
	  --build-arg REDIST_ETAG=$$2 \
	  -f $@.containerfile \
	  -t $(NVIDIA_REDIST_DRV_IMG) \
	  empty

lact-redist: _empty
	@status=$$(CRE=$(CRE) scripts/redist-check.sh $(if $(FORCE),--force) $(LACT_URL) $(LACT_REDIST_IMAGE) com.nvidia/lact.redist) || { \
	  if [ -z "$(FORCE)" ] && $(CRE) image exists $(LACT_REDIST_IMAGE) ; then \
	  echo "WARN: remote unreachable, using existing $(LACT_REDIST_IMAGE)" ; \
	  exit 0 ; \
	  fi ; \
	  echo "ERROR: remote unreachable (no size/etag for LABELs) and no usable local image $(LACT_REDIST_IMAGE)" >&2 ; \
	  exit 1 ; \
	  } ; \
	  case $$status in \
	  up-to-date) \
	  echo "$(LACT_REDIST_IMAGE) up to date" ; \
	  exit 0 ;; \
	  esac ; \
	  set -- $$status ; shift ; \
	  $(CRE) build \
	  --build-arg LACT_VER=$(LACT_VER) \
	  --build-arg LACT_URL=$(LACT_URL) \
	  --build-arg LACT_SIZE=$$1 \
	  --build-arg LACT_ETAG=$$2 \
	  -f $@.containerfile \
	  -t $(LACT_REDIST_IMAGE) \
	  empty

nvidia-xorg: nvidia-base nvidia-redist-drv
	did=$$($(CRE) inspect --format "{{.Id}}" $(NVIDIA_REDIST_DRV_IMG)) || exit 1 ; \
	  $(CRE) build \
	  --build-arg BASE_IMAGE=$(NVIDIA_BASE_IMAGE) \
	  --build-arg DRIVER_REDIST_IMAGE=$(NVIDIA_REDIST_DRV_IMG) \
	  --build-arg DRIVER_REDIST_IMAGE_ID=$$did \
	  -f $@.containerfile \
	  -t $(NVIDIA_XORG_IMAGE) \
	  resources

nvidia-lact: nvidia-base nvidia-redist-drv lact-redist
	did=$$($(CRE) inspect --format "{{.Id}}" $(NVIDIA_REDIST_DRV_IMG)) || exit 1 ; \
	  lid=$$($(CRE) inspect --format "{{.Id}}" $(LACT_REDIST_IMAGE)) || exit 1 ; \
	  $(CRE) build \
	  --build-arg BASE_IMAGE=$(NVIDIA_BASE_IMAGE) \
	  --build-arg DRIVER_REDIST_IMAGE=$(NVIDIA_REDIST_DRV_IMG) \
	  --build-arg LACT_REDIST_IMAGE=$(LACT_REDIST_IMAGE) \
	  --build-arg DRIVER_REDIST_IMAGE_ID=$$did \
	  --build-arg LACT_REDIST_IMAGE_ID=$$lid \
	  -f $@.containerfile \
	  -t $(NVIDIA_LACT_IMAGE) \
	  resources

nvidia-lact-autoswitch: nvidia-lact
	$(CRE) build \
	  --build-arg LACT_IMAGE=$(NVIDIA_LACT_IMAGE) \
	  -f $@.containerfile \
	  -t $(NVIDIA_LACT_AUTOSWITCH_IMAGE) \
	  resources

nvidia-cuda-devel: nvidia-base nvidia-xorg
	xid=$$($(CRE) inspect --format "{{.Id}}" $(NVIDIA_XORG_IMAGE)) || exit 1 ; \
	  $(CRE) build \
	  --build-arg BASE_IMAGE=$(NVIDIA_BASE_IMAGE) \
	  --build-arg NVIDIA_XORG_IMAGE=$(NVIDIA_XORG_IMAGE) \
	  --build-arg NVIDIA_XORG_IMAGE_ID=$$xid \
	  --build-arg CUDA_REPO_BASE=$(CUDA_REPO_BASE) \
	  --build-arg CUDA_PKG_SERIES=$(CUDA_PKG_SERIES) \
	  --build-arg "CUDA_DEVEL_SET=$(CUDA_DEVEL_SET)" \
	  -f $@.containerfile \
	  -t $(NVIDIA_CUDA_DEVEL_IMG) \
	  empty

nvidia-cuda-libs: nvidia-xorg nvidia-base
	xid=$$($(CRE) inspect --format "{{.Id}}" $(NVIDIA_XORG_IMAGE)) || exit 1 ; \
	  $(CRE) build \
	  --build-arg BASE_IMAGE=$(NVIDIA_BASE_IMAGE) \
	  --build-arg NVIDIA_XORG_IMAGE=$(NVIDIA_XORG_IMAGE) \
	  --build-arg NVIDIA_XORG_IMAGE_ID=$$xid \
	  --build-arg CUDA_REPO_BASE=$(CUDA_REPO_BASE) \
	  --build-arg CUDA_PKG_SERIES=$(CUDA_PKG_SERIES) \
	  --build-arg "CUDA_RUNTIME_SET=$(CUDA_RUNTIME_SET)" \
	  -f $@.containerfile \
	  -t $(NVIDIA_CUDA_LIBS_IMG) \
	  empty

nvidia-nccl-devel: nvidia-cuda-devel
	if [ -d $(NCCL) ] ; then \
	  pushd $(NCCL) && \
	  git fetch origin $(NCCL_REF) && \
	  popd || exit 1 ; \
	  else \
	  git clone -o origin --branch $(NCCL_REF) $(NCCL_REPO) $(NCCL) || exit 1; \
	  pushd $(NCCL) && \
	  git fetch origin $(NCCL_REF) && \
	  popd || exit 1 ; \
	  fi ; \
	  pushd $(NCCL) && \
	  git checkout -f FETCH_HEAD && \
	  popd || exit 1 ; \
	  printf '**/.git\n' > $(NCCL)/.containerignore ; \
	  $(CRE) build \
	  --build-arg CUDA_DEVEL_IMAGE=$(NVIDIA_CUDA_DEVEL_IMG) \
	  --build-arg NVCC=$(NVCC) \
	  --build-arg CUDA_ARCH=$(CUDA_ARCH) \
	  --build-arg CUDA_VER=$(NVIDIA_CUDA_VER) \
	  --build-arg GCC_VER=$(GCC_VER) \
	  -f $@.containerfile \
	  -t $(NCCL_DEVEL_IMAGE) \
	  $(NCCL)

nvidia-nccl-libs: nvidia-nccl-devel nvidia-cuda-libs
	ndid=$$($(CRE) inspect --format "{{.Id}}" $(NCCL_DEVEL_IMAGE)) || exit 1 ; \
	  $(CRE) build \
	  --build-arg NCCL_DEVEL_IMAGE=$(NCCL_DEVEL_IMAGE) \
	  --build-arg NCCL_DEVEL_IMAGE_ID=$$ndid \
	  --build-arg BASE_IMAGE=$(NVIDIA_CUDA_LIBS_IMG) \
	  --build-arg CUDA_VER=$(NVIDIA_CUDA_VER) \
	  -f $@.containerfile \
	  -t $(NCCL_LIBS_IMAGE) \
	  empty

nvidia-nccl: nvidia-nccl-devel nvidia-nccl-libs

llama-cpp-cuda: nvidia-nccl
	if [ -d $(LLAMA_CPP) ] ; then \
	  pushd $(LLAMA_CPP) && \
	  git fetch origin $(LLAMA_CPP_REF) && \
	  popd || exit 1 ; \
	  else \
	  git clone -o origin --branch $(LLAMA_CPP_REF) $(LLAMA_CPP_REPO) $(LLAMA_CPP) || exit 1; \
	  pushd $(LLAMA_CPP) && \
	  git fetch origin $(LLAMA_CPP_REF) && \
	  popd || exit 1 ; \
	  fi ; \
	  pushd $(LLAMA_CPP) && \
	  git checkout -f FETCH_HEAD && \
	  popd || exit 1 ; \
	  printf '**/.git\n' > $(LLAMA_CPP)/.containerignore ; \
	  $(CRE) build \
	  --build-arg BASE_IMAGE=$(NCCL_LIBS_IMAGE) \
	  --build-arg CUDA_DEVEL_IMAGE=$(NCCL_DEVEL_IMAGE) \
	  --build-arg NVCC=$(NVCC) \
	  --build-arg CUDA_ARCH=$(CUDA_ARCH) \
	  --build-arg GCC_VER=$(GCC_VER) \
	  --build-arg LLAMA_CPP_REF=$(LLAMA_CPP_REF) \
	  --build-arg LLAMA_CPP_REPO=$(LLAMA_CPP_REPO) \
	  --build-arg LLAMA_CPP_SHA=$$(git -C $(LLAMA_CPP) rev-parse HEAD) \
	  -f $@.containerfile \
	  -t $(LLAMA_CPP_IMAGE) \
	  $(LLAMA_CPP)

llama-cpp-cuda-debug: llama-cpp-cuda nvidia-nccl-devel _empty
	$(CRE) build \
	  --build-arg BASE_IMAGE=$(NCCL_DEVEL_IMAGE) \
	  --build-arg LLAMA_IMAGE=$(LLAMA_CPP_IMAGE) \
	  -f $@.containerfile \
	  -t $(LLAMA_DEBUG_IMAGE) \
	  empty

systemd:
	[ -f local.mk ] || { echo "ERROR: no local.mk (cp local.mk.example local.mk, fill in values)" >&2; exit 1; }
	mkdir -p $(HOST_ROOT)/etc/systemd/system $(HOST_ROOT)/etc/sysconfig $(HOST_ROOT)/usr/local/bin
	cp resources/driver/nvidia-kmod.service \
	  resources/driver/nvidia-card-setting.service \
	  resources/driver/lact-autoswitch.service \
	  resources/llama/llama-cpp.service \
	  resources/llama/llama-cpp-watcher.service \
	  $(HOST_ROOT)/etc/systemd/system/
	sed "s|@LLM_NFS_SERVER@|$(LLM_NFS_SERVER)|g" resources/systemd/var-local-llm.mount > $(HOST_ROOT)/etc/systemd/system/var-local-llm.mount
	chmod 0644 $(HOST_ROOT)/etc/systemd/system/var-local-llm.mount
	cp scripts/llama-cpp-watcher.sh $(HOST_ROOT)/usr/local/bin/
	chmod 0755 $(HOST_ROOT)/usr/local/bin/llama-cpp-watcher.sh
	cp scripts/nvidia-kmod-select.sh $(HOST_ROOT)/usr/local/bin/
	chmod 0755 $(HOST_ROOT)/usr/local/bin/nvidia-kmod-select.sh
	$(CURDIR)/scripts/sysconfig-gen.sh $(HOST_ROOT)/etc/sysconfig nvidia-kmod \
	  --build KMOD_IMAGE=$(NVIDIA_KMOD_IMAGE)
	$(CURDIR)/scripts/sysconfig-gen.sh $(HOST_ROOT)/etc/sysconfig nvidia-card-setting \
	  --build LACT_IMAGE=$(NVIDIA_LACT_IMAGE) \
	  --default PWR_LIMIT=140 \
	  --default MEM_CLOCK_OFFSET=1000 \
	  --default CORE_CLOCK_OFFSET=0 \
	  --default FAN_MODE=curve \
	  --default "FAN_CURVE=45:0.30 65:0.40 70:0.65 75:0.80" \
	  --default PER_CARD_OVERRIDES= \
	  --default SAFE_PL=120 \
	  --default SAFE_FAN_STATIC=0.60 \
	  --default SAFE_PM_MODE=Auto \
	  --default IDLE_PL=100 \
	  --default IDLE_PM_MODE=Auto \
	  --default IDLE_MEM_CLOCK=405 \
	  --default LOCKED_CORE_CLOCK=2000 \
	  --default LOCKED_MEM_CLOCK=8500 \
	  --default LOCKED_MEM_OFFSET=2000 \
	  --default LOCKED_PL=140 \
	  --default LOCKED_PM_MODE=PreferMaximumPerformance
	$(CURDIR)/scripts/sysconfig-gen.sh $(HOST_ROOT)/etc/sysconfig lact-autoswitch \
	  --build LACT_AUTOSWITCH_IMAGE=$(NVIDIA_LACT_AUTOSWITCH_IMAGE) \
	  --default LLAMA_URL=$(LLAMA_URL) \
	  --default LLAMA_MODEL=$(LLAMA_MODEL) \
	  --default LLAMA_KEYS_FILE=$(LLAMA_KEYS_FILE) \
	  --default KEY_MARKER=lact-autoswitch \
	  --default POLL_INTERVAL=5 \
	  --default THERMAL_EVERY=3 \
	  --default TIME_IDLE=120 \
	  --default TIME_DOWN=300 \
	  --default TEMP_SAFE=82 \
	  --default TIME_SAFE_DUR=300 \
	  --default TEMP_SAFE_BACK_DELTA=4 \
	  --default TIME_SAFE_BACK_DUR=300 \
	  --default TIME_DOWN_LACT=60 \
	  --default FALLBACK_PL=120 \
	  --default HISTORY_LINES=2000
	$(CURDIR)/scripts/sysconfig-gen.sh $(HOST_ROOT)/etc/sysconfig llama-cpp \
	  --build LLAMA_IMAGE=$(LLAMA_CPP_IMAGE) \
	  --default LLAMA_LOG_TIMESTAMPS=1 \
	  --default LLAMA_PORT=$(LLAMA_PORT) \
	  --default LLAMA_SHM_SIZE=1g \
	  --default LLAMA_UID=1001001 \
	  --default LLAMA_MEM=120g
	if [ -f $(HOST_ROOT)$(LLAMA_KEYS_FILE) ] ; then chmod 640 $(HOST_ROOT)$(LLAMA_KEYS_FILE) ; fi
	$(SYSTEMDCTL) daemon-reload
	$(SYSTEMDCTL) enable nvidia-kmod.service nvidia-card-setting.service llama-cpp.service var-local-llm.mount lact-autoswitch.service llama-cpp-watcher.service

# Безопасный рестарт/стоп/старт живого llama-cpp-сервера (Этап 25).
# Скрипт исполняется в шелле toolbx через setsid -f (self-healing:
# переживает сессию); хост — через CRE/chroot, как в systemd-таргете.
# Протокол/состояния: LIVE-SERVER.md.
MODE ?= restart
IDLE_TIMEOUT ?= 30
READY_TIMEOUT ?= 600
VERIFY_REQUEST ?=
RESTART_LOG ?= /tmp/llm-rig/llama-cpp-restart.log

llama-cpp-restart:
	[ -f local.mk ] || { echo "ERROR: no local.mk (cp local.mk.example local.mk, fill in values)" >&2; exit 1; }
	mkdir -p "$(dir $(RESTART_LOG))"
	setsid -f env CRE="$(CRE)" HOST_ROOT="$(HOST_ROOT)" SYSTEMDCTL="$(SYSTEMDCTL)" \
	  LLAMA_URL="$(LLAMA_URL)" LLAMA_MODEL="$(LLAMA_MODEL)" \
	  LLAMA_KEYS_FILE="$(LLAMA_KEYS_FILE)" LLAMA_CONTAINER="$(LLAMA_CPP)" \
	  OPENCODE_CONFIG="$(OPENCODE_CONFIG)" \
	  ./scripts/llama-cpp-restart.sh "$(MODE)" --idle-timeout "$(IDLE_TIMEOUT)" \
	  --ready-timeout "$(READY_TIMEOUT)" $(if $(VERIFY_REQUEST),--verify-request "$(VERIFY_REQUEST)") \
	  < /dev/null >> "$(RESTART_LOG)" 2>&1
	@echo "llama-cpp-restart: started (log=$(RESTART_LOG), status=/tmp/llm-rig/llama-cpp-restart.status)"
