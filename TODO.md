# TODO — llm-rig

Контейнеризованные компоненты хоста для быстрого развёртывания
LLM (NVIDIA): модули ядра, драйвер, OC/авто-свитч, рантаймы LLM,
мониторинг. Сборка — `Makefile` + `*.containerfile` (инструмент
контейнеров — переменная `CRE`).

Провенанс: репо выделено из приватного архив-репо (полная
история: Этапы 1-19, Xid 13 — ветка `xid13-crash`); URL архива не
публикуется. Конвенция этапов — как в архиве: брейншторм →
спека → план → исполнение.

## Локальная конфигурация

`local.mk` (untracked, gitignored) — machine-local значения
(`LLAMA_HOST`, `LLM_NFS_SERVER`). `cp local.mk.example local.mk`,
заполнить. `make systemd` без local.mk — fail-loud.

## Этапы

- [x] 20. local.mk + чистое репо (выделено из архива: без
  процесс-доков и истории; дерево чувствительно-чистое —
  `scripts/test-no-sensitive.sh`)

### 21. Ollama-рантайм (перенос из архива, Этап 10)
- [ ] ollama.containerfile + make-цель (по образцу llama-cpp-cuda)
- [ ] ollama.service + sysconfig (по образцу llama-cpp.service)
- [ ] pin-тесты (graph-тест: deploy + sysconfig; no-sensitive: значения)

### 22. Jupyter-рантайм (перенос из архива, Этап 9)
- [ ] jupyter.containerfile + make-цель
- [ ] jupyter.service (system-user, не pydorok-подход) + sysconfig
- [ ] pin-тесты

### 23. Остатки плана из архива (выборочно)
- [x] cache-ram: вытеснение/restore — верификация на живом контейнере (2026-09-02, отчёт: docs/superpowers/reports/2026-09-02-cache-ram-verification.md)
- [x] док: README-секции по развёртыванию (с local.mk)

### 27. lact-autoswitch: pin `safe` при crash/thermal-loop

Смысл (архив: спека Этапа 10 §1.7–1.8 «Demote в safe при повторных
крахах — вне скоупа», спека Этапа 16.2 §2 «Владелец профилей GPU —
хелпер»; поглощает «эскалация по числу child-крахов (Этап 10)»):
OC → крах llama.cpp (Xid 13) → watcher оживляет → OC → крах (цикл);
либо перегрев → safe → остывание → OC (цикл). После повторных
событий — принудительный pin `safe`; снятие — операторским `rm`
pin-файла (после того, как оператор разберётся). До Этапа 27 способ
фиксации — `systemctl stop lact-autoswitch` (при старте хелпер adopts
фактический профиль).

- [x] Спека (канал watcher→хелпер, триггеры/политика, снятие) —
      `docs/superpowers/specs/2026-09-03-stage27-pin-safe-design.md`
- [x] План + исполнение —
      `docs/superpowers/plans/2026-09-03-stage27-pin-safe.md`, live-окно
      04.09.2026 (отчёт `docs/superpowers/reports/2026-09-03-stage27-pin-safe.md`)

### 24. CUDA toolkit: NVIDIA fedora44 dnf-репо (13.2.2 → 13.3.1)
- [x] Пре-чек: dnf5×репо, NEVRA-пины, weakdeps, размещение файлов,
      runtime-сет на GPU, пробы сборки NCCL/llama на 13.3.1 (отчёт)
- [x] Основная спека (по фактам пре-чека,
      `docs/superpowers/specs/2026-09-01-cuda-repo-design.md`, ревью OK)
- [x] Реализация: cuda-devel/cuda-libs через dnf (имена серии,
      опция точных NEVRA), убрать `nvidia-redist-cuda`,
      `/opt/cuda` → `/usr/local/cuda`, Makefile, тесты
- [x] Live-окно: пересборка всей цепи + прогон llama-server
      (02.09.2026, отчёт `docs/superpowers/reports/2026-09-02-stage24-cuda-repo.md`)

### 25. Безопасный рестарт живого сервера (фоллоу-ап live-окна Этапа 24)
Спека: `docs/superpowers/specs/2026-09-02-safe-restart-design.md`
(наработки по рестарту — в архиве, nvidia-aiml/docs/superpowers)
- [x] `scripts/llama-cpp-restart.sh` (check/restart/stop/start) +
      `make llama-cpp-restart`: wait-idle (поллинг `/slots`
      `is_processing`, параметр, дефолт 30 c → abort rc=3), `setsid -f`
      (self-healing: переживает сессию), правило SAME_HOST (opencode
      baseURL + CRE-контейнер + порт), ready-gate `/v1/models` loaded,
      verify-curl; hermetic-тест (mock-сервер + PATH-stubs)
- [x] `LIVE-SERVER.md` (корень, tracked, без секретов): работа с живым
      сервером (эндпоинты, ключи `/etc/llama/llama-cpp-keys.txt`,
      sysconfig, watcher, даунтайм/загрузка модели) + правило в
      `AGENTS.md` (деятельностный триггер)
- [x] `local.mk`: только опциональная `OPENCODE_CONFIG` (анализ —
      спека, секция «local.mk»)
- [x] live-окно: in-flight-тест (abort rc=3) + полный рестарт с замером
      таймлайна; приёмка — сессия переживает рестарт (02.09, отчёт
      `docs/superpowers/reports/2026-09-02-stage25-safe-restart.md`)

### 26. llama-cpp non-root

Решение (03.09): откат на root build/deploy/debug (rootful toolbx) —
из «Non-root окружения» оставляем только запуск контейнера `llama-cpp`
non-root (`-u ${LLAMA_UID}:0`, без `--privileged`).

Спека: `docs/superpowers/specs/2026-09-03-llama-cpp-nonroot-design.md`
- [x] `llama-cpp.service`: снять `--privileged`; добавить
      `-u ${LLAMA_UID}:0`, `-m ${LLAMA_MEM}`, `--ulimit memlock=-1:-1`
      (модель mlock), `--device nvidiactl/nvidia-uvm`; маунт
      `/etc/llama:/llama:ro` + `--models-preset /llama/llama.ini`
- [x] keys `/etc/llama/llama-cpp-keys.txt`: `chmod 640` (root:root,
      group 0 читает) — idempotent-шаг в `make systemd`
- [x] sysconfig `llama-cpp`: `LLAMA_UID=1001001`, `LLAMA_MEM=120g`
      (стартовое; при OOM оператор поднимает — рост с трафиком,
      отчёт §Память), `LLAMA_SHM_SIZE=1g` (было 64g; факт 185M =
      NCCL/CUDA IPC)
- [x] `test-systemd-units.sh` (pin новых флагов), `LIVE-SERVER.md`
      (non-root + цифры памяти); containerfile — без изменений
      (`/app` уже 755)
- [x] live-окно: safe-restart → `podman exec llama-cpp id` = non-root,
      keyed-эндпоинты, GPU/model-load, memlock, замеры памяти (отчёт
      `docs/superpowers/reports/2026-09-03-stage26-llama-cpp-nonroot.md`)

Отменено (откат на root): non-root-dev, привилегии через `sudo`,
container-registry (ghcr/локальный).

## Перенесено из архива (старая нумерация)

- [ ] MTP A/B perf-тест (Этап 12, целиком)
- [ ] vendor-патч llama.cpp in-process exit (Этап 10, опц.)
- [ ] stop/restart-hang при in-flight task (След-Этап 14;
      воспроизведён в live-окне Этапа 25: stop-hang 90 s → SIGABRT при
      release task в ту же секунду SIGTERM; скрипт Этапа 25 его поглощает)
- [ ] lact-autoswitch: POLL_INTERVAL 5 → 10 s (Этап 16, опц.)

## Кандидаты на этапы (без номера)

- [ ] lact-autoswitch: fan-fail — вентилятор остановился, температура
      растёт даже на `safe`-профиле (PL 120): хоум-лаб риск (не
      промышленный). Реакция — за рамками пина (полный стоп / громкий
      аларт); требует брейншторма (найден при ревью спеки Этапа 27)
