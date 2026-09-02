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
- [ ] cache-ram: вытеснение/restore — верификация на живом контейнере
- [ ] lact-autoswitch: до-состояние при пересборке драйвера
- [ ] док: README-секции по развёртыванию (с local.mk)

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
- [ ] скрипт рестарта llama-cpp из opencode (сессию держит тот же
      сервер): `setsid`, не `nohup` (nohup-процесс отваливается по
      таймауту tool-вызова opencode); алгоритм: 1) ждать завершения
      инференса (параметр, дефолт 30 c), 2) рестарт или выключить
      (ожидание) / включить, 3) curl-запрос к модели (параметр —
      модель/запрос); наработки — в архиве (nvidia-aiml,
      docs/superpowers)
- [ ] `AGENTS.md-local` (машинозависимое, gitignored, не в репо): как
      работать с живым сервером llama-cpp (рестарт, API-ключи в
      `/etc/llama/llama-cpp-keys.txt` — файл с комментариями, sysconfig,
      watcher, даунтайм/загрузка модели)

### 26. Non-root окружение (пока на подумать, без спеки)
- [ ] разработку вести от имени обычного пользователя (не root)
- [ ] привилегированные действия — через `sudo`
- [ ] перейти на container-registry (рассмотреть ghcr или локальный)

## Перенесено из архива (старая нумерация)

- [ ] MTP A/B perf-тест (Этап 12, целиком)
- [ ] vendor-патч llama.cpp in-process exit (Этап 10, опц.)
- [ ] stop/restart-hang при in-flight task (След-Этап 14)
- [ ] эскалация по числу child-крахов (Этап 10)
- [ ] lact-autoswitch: POLL_INTERVAL 5 → 10 s (Этап 16, опц.)
