# Спека: CUDA toolkit через NVIDIA fedora44 dnf-репо (Этап 24, основная)

- Дата: 01.09.2026
- Статус: ревью пройдено (01.09.2026); live-окно — отдельная фаза после плана
- Источник: `TODO.md`, «Этап 24: CUDA toolkit: NVIDIA fedora44 dnf-репо
  (13.2.2 → 13.3.1)»
- Основа: отчёт пре-чека
  `docs/superpowers/reports/2026-09-01-cuda-repo-precheck.md` (завершён,
  таблица решений §6 заполнена, все факты верифицированы; ссылок ниже —
  по разделам отчёта)
- Связь: после ревью — план реализации (writing-plans) → SDD → live-окно
  → finishing (merge в `main`)

## Контекст

Подход A утверждён пользователем (брейншторм 01.09.2026): источник CUDA
toolkit — официальный dnf-репо NVIDIA для fedora44, `.run`-redist-канал
для toolkit убирается, CUDA 13.2.2 → 13.3.1. Драйвер 610.43.03
(userspace + kmod), LACT, kernel-цепь — не меняются.

Уточнение механизма (01.09.2026, решение пользователя): вместо
«17 точных NEVRA в containerfile» — **имена серии** `*-13-3` (dnf
решает самый свежий release, F10) + **опция точных NEVRA** override'ом
`CUDA_DEVEL_SET`/`CUDA_RUNTIME_SET` в `local.mk` — универсальность
старого механизма «указал версию — скачалось и поставилось» + гибкость
выбора конкретного патча.

Все «неверифицированные факты» пре-чек-спеки (пп.1–10) закрыты отчётом;
дизайн ниже опирается только на верифицированные факты.

## Цель

Перевести цепочку образов CUDA toolkit на dnf-репо с точными NEVRA-пинами,
удалить `.run`-канал toolkit, пересобрать цепь в live-окне и подтвердить
работу llama-server.

## Не цели

- Драйвер 610.43.03 (`.run` + kmod), LACT, kernel-цепь — без изменений
  (userspace-драйвер по-прежнему копится из `nvidia-xorg`).
- `GCC_VER` — остаётся `15` (отчёт §4: nvcc 13.3.1 отклоняет gcc16,
  `#error` в host_config.h; переворот — отдельное решение, не это окно).
- `ncu`/`nsys` (`cuda-nsight-*`) — в репо не используются (отчёт §9).
- Ollama/jupyter — ссылок на `/opt/cuda` нет (проверено брейнштормом).
- Зеркало Fedora — отдельное: `REPO_BASE_URL` уже перенесён в
  `local.mk` (мемо `2026-09-01-repo-base-url-local-mk`, опционал со
  стандартным фолбэком); зеркало `mirror.getpods.ru` починено владельцем
  (01.09.2026, верифицировано: `local.repo` + repomd'ы `fedora`/`updates`
  → 200).

## Верифицированные факты (основания дизайна)

| # | Факт | Отчёт |
|---|---|---|
| F1 | devel-набор = 7 NEVRA + `cuda-driver-devel-13-3-13.3.29-1` (стуб `libcuda.so` → `CUDA::cuda_driver` в cmake; без него Generate step падает) + `cuda-sanitizer-13-3-13.3.75-1` (debug-инструментарий, ноль Requires, 17 MB) | §1, §2, §5 (доп. проба), §9 |
| F2 | NEVRA-пины — **без суффикса `.rpm`** (dnf5: суффикс = путь к локальному файлу) | §2 п.2 |
| F3 | `--setopt=install_weak_deps=False`: дельта weakdeps = 10 пакетов / 12.0 MiB, все — базовый тулчейн, ни одного CUDA-пакета → отключаем | §2 п.3 |
| F4 | Размещение: всё под `/usr/local/cuda-13.3/targets/x86_64-linux/lib` (+ hardlink'd `lib64`); `/usr/local/cuda` — package alternatives; `/etc/ld.so.conf.d`-входы (`000_cuda.conf`, `987_cuda-13.conf`) — **поставлены пакетами**; собственный ldconfig conf/ln не нужен | §2 п.4 |
| F5 | runtime-набор = 8 NEVRA, достаточен (hello + hello_dyn на GPU: 7/8 пакетов динамически подгружаются, cublas/cufft/curand — точные ответы; `libnvfatbin` — присутствующий лист) | §3 |
| F6 | NCCL v2.31.2-1: g++15 OK (132 s), g++16 FAIL | §4 |
| F7 | llama.cpp configure OK: CUDA 13.3.73, NCCL по `NCCL_ROOT=/usr/local/cuda` (`/usr/local/cuda/lib64/libnccl.so`), при `NVCC=/usr/local/cuda/bin/nvcc` + `cuda-driver-devel` | §5 |
| F8 | Размеры: devel-набор 3.60 GiB (29 пакетов, weakdeps off); runtime-образ 2.63 GB (vs старые 8.72 / 5.3 / 5.46 GB) | §2 п.5, §3.3, §7 |
| F9 | `dnf makecache` — exit 0 при частичном сбое метаданных (не health-check); ошибка проявляется в транзакции fail-loud | §2.1, §7 |
| F10 | Установка по имени пакета (без версии): dnf5 выбирает **самый свежий release имени**; несуществующее имя — fail-loud exit 1 («Нет соответствия для аргумента»). Проверено 01.09.2026 (пробы в throwaway-контейнере на `nvidia-base:44`, `repoquery`/`install --assumeno`): у всех 17 имён наборов **свежайший release на сегодня = ровно NEVRA-набор отчёта §1** (у части имён в репо соседствуют более старые релизы: `libcublas-13-3` 13.5.1.27/13.6.0.2, `libcusolver-13-3` 12.2.2.18/12.2.6.9, `libcusparse-13-3` 12.8.1.7/12.8.2.51, `cuda-minimal-build-13-3` 13.3.0/13.3.1, `cuda-sanitizer-13-3` 13.3.27/13.3.75 — дnf берёт свежий) | пробы 01.09 |

## Наборы пакетов: серия + опция точных NEVRA

Решение (01.09.2026, пользователь): вернуть универсальность старого
механизма — «указал версию — скачалось и поставилось» — сохранив
возможность указать точный патч (аналог старого `NVIDIA_CUDA_132`
URL-вариабля). Имена пакетов репо несут серию major-minor
(`-13-3`), патч-релиз выбирает dnf (F10):

- **По умолчанию — имена серии** (`cuda-cudart-13-3`, …): dnf берёт
  самый свежий release каждой серии в одной транзакции (сегодня —
  ровно верифицированный набор отчёта §1, F10).
- **Точный патч — override списка в `local.mk`** (или командной
  строке): `CUDA_DEVEL_SET`/`CUDA_RUNTIME_SET` = пробельный список
  полных NEVRA (без `.rpm`-суффикса, F2). Containerfile не меняется.

**Состав наборов (имена серии, 01.09.2026):**

- **Devel (9, `nvidia-cuda-devel`):** `cuda-minimal-build`,
  `cuda-driver-devel` (стуб `libcuda.so`, F1), `cuda-sanitizer`
  (debug-инструментарий, §9), `libcublas-devel`, `libcufft-devel`,
  `libcurand-devel`, `libcusolver-devel`, `libcusparse-devel`,
  `libnvjitlink-devel` — все с суффиксом серии `-13-3`.
- **Runtime (8, `nvidia-cuda-libs`):** `cuda-cudart`, `libcublas`,
  `libcufft`, `libcurand`, `libcusolver`, `libcusparse`,
  `libnvfatbin`, `libnvjitlink` — все с суффиксом серии `-13-3`.

Точные NEVRA «сегодняшнего» разрешения (для аудита и будущего
перепиннинга) — отчёт §1; в собранных образах фиксируется
аудит-файлом (п.2/п.3).

Транзитно подтягиваются (не пинятся): cccl, cuda-compiler, cuda-nvcc,
cuda-crt, cuda-cudart(-devel), cuda-culibos-devel, cuda-cuobjdump,
cuda-cuxxfilt, cuda-nvprune, cuda-profiler-api, cuda-tileiras,
cuda-ctadvisor, 3 noarch `cuda-toolkit-*-config-common` (отчёт §2).

## Дизайн

### 1. `Makefile`

| Изменение | Было | Стало |
|---|---|---|
| `NVIDIA_CUDA_VER` | `?= 13.2` | `?= 13.3` (major.minor; управляет тегом образа, layout-путями и серией пакетов) |
| `NVCC` | `?= /opt/cuda/bin/nvcc` | `?= /usr/local/cuda/bin/nvcc` |
| `CUDA_REPO_BASE` | — | `?= https://developer.download.nvidia.com/compute/cuda/repos/fedora44/x86_64` |
| `CUDA_PKG_SERIES` | — | `?= $(subst .,-,$(NVIDIA_CUDA_VER))` (13.3 → `13-3`) |
| `CUDA_DEVEL_SET` | — | `?= cuda-minimal-build-$(CUDA_PKG_SERIES) cuda-driver-devel-$(CUDA_PKG_SERIES) cuda-sanitizer-$(CUDA_PKG_SERIES) libcublas-devel-$(CUDA_PKG_SERIES) libcufft-devel-$(CUDA_PKG_SERIES) libcurand-devel-$(CUDA_PKG_SERIES) libcusolver-devel-$(CUDA_PKG_SERIES) libcusparse-devel-$(CUDA_PKG_SERIES) libnvjitlink-devel-$(CUDA_PKG_SERIES)` |
| `CUDA_RUNTIME_SET` | — | `?= cuda-cudart-$(CUDA_PKG_SERIES) libcublas-$(CUDA_PKG_SERIES) libcufft-$(CUDA_PKG_SERIES) libcurand-$(CUDA_PKG_SERIES) libcusolver-$(CUDA_PKG_SERIES) libcusparse-$(CUDA_PKG_SERIES) libnvfatbin-$(CUDA_PKG_SERIES) libnvjitlink-$(CUDA_PKG_SERIES)` |
| `NVIDIA_CUDA_118/120/121/122/132`, `NVIDIA_CUDA_URL`, `NVIDIA_REDIST_CUDA_IMG` | есть | удалить |
| цель `nvidia-redist-cuda` | есть | удалить |
| `nvidia-cuda-devel` | deps `nvidia-base nvidia-xorg nvidia-redist-cuda`; аргы `CUDA_REDIST_IMAGE{,_ID}` | deps `nvidia-base nvidia-xorg`; аргы `−CUDA_REDIST_IMAGE{,_ID}` `+CUDA_REPO_BASE +CUDA_PKG_SERIES +CUDA_DEVEL_SET` |
| `nvidia-cuda-libs` | deps `nvidia-cuda-devel nvidia-xorg nvidia-base`; аргы `CUDA_DEVEL_IMAGE{,_ID}` | deps `nvidia-xorg nvidia-base`; аргы `−CUDA_DEVEL_IMAGE{,_ID}` `+CUDA_REPO_BASE +CUDA_PKG_SERIES +CUDA_RUNTIME_SET` |

Без изменений: `NVIDIA_DRV_VER`, `NVIDIA_DRV_RUN_URL`, LACT,
`NCCL_REF ?= v2.31.2-1`, `CUDA_ARCH ?= 86`, `GCC_VER ?= 15`,
`NVIDIA_BASE_IMAGE`/`nvidia-base`, systemd, redist-check для драйвера
(`nvidia-redist-drv` остаётся).

Семантика `CUDA_DEVEL_SET`/`CUDA_RUNTIME_SET` (решение 01.09.2026):
по умолчанию — имена серии (dnf решает самый свежий release, F10);
override в `local.mk` полным списком NEVRA = точный патч, как старый
URL-варианбл. В `local.mk.example` — комментарий-документация
механизма (без значений: инвариант test-no-sensitive «значения
local.mk не в tracked-файлах»).

### 2. `nvidia-cuda-devel.containerfile` (переписать)

Текущий: base + drv-libs copy из `nvidia-xorg` + `installer.sh --toolkit`
+ `ln -s /opt/cuda` + собственный `20_local.conf`. Новый:

```dockerfile
ARG BASE_IMAGE
ARG NVIDIA_XORG_IMAGE
ARG CUDA_REPO_BASE

# nvidia-drv-libs: nvidia-xorg (driver user-space libs), injected by Makefile
FROM ${NVIDIA_XORG_IMAGE} as nvidia-drv-libs

# base: nvidia-base (fedora-minimal + dnf), injected by Makefile
FROM ${BASE_IMAGE}

ARG NVIDIA_XORG_IMAGE_ID
ARG CUDA_REPO_BASE
ARG CUDA_PKG_SERIES
ARG CUDA_DEVEL_SET

RUN \
  --mount=type=bind,from=nvidia-drv-libs,source=/,target=/mnt/drv-libs \
  set -euxo pipefail ; \
  curl -fsLo /etc/yum.repos.d/cuda-fedora44.repo $CUDA_REPO_BASE/cuda-fedora44.repo ; \
  cp -arv /mnt/drv-libs/opt/nvidia/ /opt/nvidia/ && \
  cp -av /mnt/drv-libs/usr/lib64/libcuda* /usr/lib64/ && \
  cp -av /mnt/drv-libs/usr/lib64/libnvidia* /usr/lib64/ && \
  ln -s /opt/nvidia/10_local.conf /etc/ld.so.conf.d/ && \
  dnf install -y --setopt=install_weak_deps=False $CUDA_DEVEL_SET \
  && \
  dnf clean all && \
  ldconfig && \
  rpm -qa | grep -- "-${CUDA_PKG_SERIES}-" | sort > /usr/local/cuda-installed.txt
```

Обоснование по строкам:

- `curl .../cuda-fedora44.repo` — доставка репо (F-факт §2 п.1: dnf5 +
  remote gpgkey + gpgcheck=1 работает, ключ `0x73CD9B30` импортируется
  автоматически); имя файла и URL верифицированы отчётом §1.
- drv-libs copy — **без изменений** (драйвер не мигрируется);
  `10_local.conf` — драйверская, остаётся.
- `dnf install $CUDA_DEVEL_SET` — 9 пакетов devel-набора (F1): 7 +
  `cuda-driver-devel` (обязателен, F1) + `cuda-sanitizer`
  (debug-инструментарий, §9 — в cuda-devel, не в debug-образ:
  эквивалент старому миру, у debug-образа нет dnf-стадии, прод не
  затрагивается). По умолчанию — имена серии (F10); точные NEVRA —
  override `CUDA_DEVEL_SET` (решение 01.09.2026).
- Аудит-файл `/usr/local/cuda-installed.txt`: точные установленные
  NEVRA серии (фильтр `-${CUDA_PKG_SERIES}-` в `rpm -qa` — все CUDA-
  пакеты несут маркер серии в имени; драйверские `libnvidia-*` и
  fedora-пакеты маркера не имеют). Что именно стоит в образе — всегда
  видно; при желании перепиннить точно — список прямо из файла.
- weakdeps off (F3); `dnf clean all`; `ldconfig` (пересобрать кэш:
  драйверские lib + пакетные conf `000_cuda.conf`/`987_cuda-13.conf`).
- **Нет** `ln -s /opt/cuda`, **нет** `20_local.conf` (F4: alternatives
  `/usr/local/cuda` и conf — поставлены пакетами; containerfile их не
  дублируют).
- Правило `no-inline-comments`: завершающих комментариев после
  инструкций нет.

### 3. `nvidia-cuda-libs.containerfile` (переписать)

Текущий: tar-copies весь `targets/x86_64-linux/lib` из devel-образа +
собственный conf. Новый — **не зависит от devel-образа**, дnf-установка
runtime-набора (ровно конфигурация пре-чека `cuda-precheck-libs:tmp`,
2.63 GB, проверена на GPU, отчёт §3):

```dockerfile
ARG BASE_IMAGE
ARG NVIDIA_XORG_IMAGE
ARG CUDA_REPO_BASE

# drv: nvidia-xorg (driver user-space libs), injected by Makefile
FROM ${NVIDIA_XORG_IMAGE} as drv

# base: nvidia-base (fedora-minimal + dnf), injected by Makefile
FROM ${BASE_IMAGE}

ARG CUDA_REPO_BASE
ARG NVIDIA_XORG_IMAGE_ID
ARG CUDA_PKG_SERIES
ARG CUDA_RUNTIME_SET

RUN \
  --mount=type=bind,from=drv,source=/,target=/mnt/drv \
  set -euxo pipefail ; \
  curl -fsLo /etc/yum.repos.d/cuda-fedora44.repo $CUDA_REPO_BASE/cuda-fedora44.repo ; \
  cp -arv /mnt/drv/opt/nvidia/ /opt/nvidia/ && \
  cp -av /mnt/drv/usr/lib64/libcuda* /usr/lib64/ && \
  cp -av /mnt/drv/usr/lib64/libnvidia* /usr/lib64/ && \
  ln -s /opt/nvidia/10_local.conf /etc/ld.so.conf.d/ && \
  dnf install -y --setopt=install_weak_deps=False $CUDA_RUNTIME_SET numactl \
  && \
  dnf clean all && \
  ldconfig && \
  rpm -qa | grep -- "-${CUDA_PKG_SERIES}-" | sort > /usr/local/cuda-installed.txt
```

- runtime-набор из 8 (F5) — `$CUDA_RUNTIME_SET` (по умолчанию имена
  серии, F10; точные NEVRA — override, решение 01.09.2026);
  `numactl` — как в текущем containerfile (parity).
- Аудит-файл `/usr/local/cuda-installed.txt` — как в п.2.
- Без собственного ldconfig conf (F4).
- Devel-зависимость снята: image строится только из `nvidia-base` +
  `nvidia-xorg` (Makefile — п.1).

### 4. `nvidia-nccl-devel.containerfile` (правка)

- `ARG NVCC=/opt/cuda/bin/nvcc` → `ARG NVCC=/usr/local/cuda/bin/nvcc`
  (Makefile передаёт явно; ARG-default — consistency).
- `cuda_home=$(dirname $(dirname ${NVCC}))` — без изменений
  (=/usr/local/cuda).
- Копирование артефактов NCCL: `/opt/cuda-${CUDA_VER}/{lib64,include,bin}`
  → `/usr/local/cuda-${CUDA_VER}/{lib64,include,bin}` (пре-чек §5: NCCL
  размещён именно так и найден llama-configure по
  `/usr/local/cuda/lib64/libnccl.so`).

### 5. `nvidia-nccl-libs.containerfile` (правка)

- `--mount=...source=/opt/cuda-${CUDA_VER}` →
  `source=/usr/local/cuda-${CUDA_VER}`.
- `cp -aP /mnt/nccl/lib64/libnccl.so* /opt/cuda-${CUDA_VER}/lib64/` →
  `/usr/local/cuda-${CUDA_VER}/lib64/`.

### 6. `llama-cpp-cuda.containerfile` (правка)

- `ARG NVCC=/opt/cuda/bin/nvcc` → `ARG NVCC=/usr/local/cuda/bin/nvcc`.
- `-DNCCL_ROOT=/opt/cuda` → `-DNCCL_ROOT=/usr/local/cuda`.
- Остальное (gcc-15, MMQ, Ninja, LABEL, ENTRYPOINT) — без изменений.

### 7. `llama-cpp-cuda-debug.containerfile`

Без изменений: base = `nvidia-nccl-devel` (devel-цепь) — санитайзер
приходит через п.2; `compute-sanitizer` —
`/usr/local/cuda/bin/compute-sanitizer` (F1/§9).

### 8. `debug/repro-llama-block3-run.sh`

- Строка 339: `--entrypoint /opt/cuda/bin/compute-sanitizer` →
  `--entrypoint /usr/local/cuda/bin/compute-sanitizer` (единственная
  ссылка в файле, проверено grep).

### 9. Удаление

- Файл `nvidia-redist-cuda.containerfile`.
- Makefile: цель `nvidia-redist-cuda` + переменные
  (`NVIDIA_CUDA_118/120/121/122/132`, `NVIDIA_CUDA_URL`,
  `NVIDIA_REDIST_CUDA_IMG`) — п.1.

### 10. `scripts/test-makefile-graph.sh`

- Секция 1 (цикл `make -n`): из списка целей убрать `nvidia-redist-cuda`;
  из аргументов `make`/`make_target` — `NVIDIA_CUDA_URL`; убрать
  `cuda_url`/`cuda.run` plumbing (использовался только redist-cuda).
- Секция `nvidia-redist-cuda` — удалить целиком.
- `nvidia-cuda-devel`: sequence без `nvidia-redist-cuda.containerfile`;
  убрать ожидания `CUDA_REDIST_IMAGE{,_ID}`; добавить ожидания
  `CUDA_REPO_BASE` (test-URL, паттерн `repo_base_url`),
  `CUDA_PKG_SERIES=test` (из `NVIDIA_CUDA_VER=test`) и первый токен
  `CUDA_DEVEL_SET` (`--build-arg
  CUDA_DEVEL_SET=cuda-minimal-build-test …`).
- `nvidia-cuda-libs`: sequence
  `nvidia-base.containerfile nvidia-redist-drv.containerfile
  nvidia-xorg.containerfile nvidia-cuda-libs.containerfile`; убрать
  ожидания `CUDA_DEVEL_IMAGE{,_ID}`; добавить ожидания `CUDA_REPO_BASE`,
  `CUDA_PKG_SERIES=test` и первый токен `CUDA_RUNTIME_SET`
  (`--build-arg CUDA_RUNTIME_SET=cuda-cudart-test …`).
- `nvidia-nccl-devel` / `nvidia-nccl-libs` / `llama-cpp-cuda`: sequence —
  без `nvidia-redist-cuda.containerfile`.
- Ожидания NVCC (2 шт., строки 415/491 в текущей версии):
  `--build-arg NVCC=/usr/local/cuda/bin/nvcc`.
- Все остальные ожидания — без изменений.

## Риски и митигации (отчёт §7 → дизайн)

| # | Риск | Митигация в дизайне |
|---|---|---|
| R1 | `dnf makecache` exit 0 при сбое метаданных (F9) | Отдельного health-check нет: при отсутствии метаданных `dnf install` fail-loud в транзакции («Нет соответствия»); сборка образа падает, не «тихо кривой» |
| R2 | В `nvidia-base:44` зашитое зеркало было мертво в окно пре-чека | Зеркало починено (01.09.2026, верифицировано 200-ми); в live-окне `nvidia-base` **пересобирается первым** (свежий `local.repo`); если зеркало умрёт снова — пересборка `nvidia-base` с пустым `REPO_BASE_URL` (стандартные репо, семантика опционала из мемо `2026-09-01-repo-base-url-local-mk`) |
| R3 | NVIDIA может убрать из репо релизы серии `13-3` (сейчас соседствуют 13.3.0/13.3.1) | Имя серии исчезнет → `dnf` fail-loud («Нет соответствия», F10) — сборка падает, не «тихо кривой»; обновление серии (`NVIDIA_CUDA_VER=13.4` — одна строка) или точный пин override'ом `CUDA_*_SET` — отдельное решение |
| R4 | `cuda-sanitizer` в репо — две версии (13.3.27 / 13.3.75) | Имя серии → dnf берёт свежую (13.3.75, F10); точная — override |
| R5 | Runtime-набор — 8 пакетов, а не полный тулкит (нет nvrtc/opencl/npp/nvjpeg и пр.) | Достаточность верифицирована для единственного потребителя (llama.cpp + NCCL, отчёт §3.7); новый потребитель — расширение набора отдельным решением |
| R6 | Имена серии (дефолт) — пересборка после выпуска нового 13.3.x **тихо** возьмёт свежий патч (старый `.run`-URL был неизменяемым) | Аудит-файл `/usr/local/cuda-installed.txt` в каждом CUDA-образе фиксирует точные установленные NEVRA — дрейф видим и проверяем; строгая репродуктивность — override `CUDA_DEVEL_SET`/`CUDA_RUNTIME_SET` точными NEVRA (список — из аудит-файла собранного образа или отчёта §1) |

## Live-окно (после SDD-реализации)

1. Пересборка цепи: `nvidia-base` (первым, R2) → `nvidia-xorg` →
   `nvidia-cuda-devel` → `nvidia-cuda-libs` → `nvidia-nccl-devel` →
   `nvidia-nccl-libs` → `llama-cpp-cuda` → `llama-cpp-cuda-debug`.
2. Протокол «снимок → restore» для прод-контейнера llama-cpp (как в
   пред. этапах): снимок работающего контейнера, пересборка, restore,
   проверка.
3. Приёмка:
   - llama-server стартует, короткая генерация OK;
   - debug-образ: `/usr/local/cuda/bin/compute-sanitizer --version` OK;
   - `ldconfig -p` в runtime-образе: 8 `.so` на месте;
   - тест-сьют репозитория — зелёный.
4. Cleanup: старые образы `*:13.2` (nvidia-redist-cuda:13.2,
   nvidia-cuda-{devel,libs}:13.2, nvidia-nccl-{devel,libs}-cuda-13.2:*,
   llama-cpp-cuda{,-debug}:13.2) — после успешного restore.

## Критерии готовности

- все файлы по пп.1–10 дизайна изменены/удалены;
- `scripts/test-makefile-graph.sh` + полный тест-сьют — зелёные;
- live-окно: цепь на 13.3, llama-server работает, санитайзер на месте,
  старые `:13.2` образы убраны;
- `TODO.md` Этап 24: чекбоксы «основная спека», «реализация»,
  «live-окно» отмечены;
- finishing-a-development-branch: merge `stage24-cuda-repo` → `main`.
