# llm-rig

Контейнеризованные компоненты хоста для быстрого развёртывания
LLM (NVIDIA): модули ядра, драйвер, OC/авто-свитч, llama.cpp,
мониторинг.

Сборка: `Makefile` + `*.containerfile` (инструмент контейнеров —
переменная `CRE`: `podman` или `podman-remote`). Кодовые правила —
`AGENTS.md`, процессные — `COORDINATOR.md`. Локальные значения —
`local.mk` (см. `local.mk.example`).

## Важные файлы и каталоги

- `TODO.md` — этапы (конвенция: брейншторм → спека → план)
- `docs/superpowers/{specs,plans,reports,memos}/` — процесс-доки
  (конвенция появится со следующего этапа)
- `local.mk` / `local.mk.example` — machine-local значения / шаблон

## Развёртывание

**Пре-рекиситы хоста:**

- podman; переменная `CRE`: `podman` (сборка на хосте) или
  `podman-remote` (сборка из toolbx — рецепты исполняются на хосте).
  В toolbx `HOST_ROOT` автоматически `/run/host`.
- Хостовое ядро (kmod собирается под него: `KVER`) и GPU NVIDIA.
  Драйвер и модули ядра даёт репо (redist → образ `kmod` → грузит
  `nvidia-kmod.service`), предустановка на хосте не нужна.
- NFS-шара с моделями (`LLM_NFS_SERVER`).

**`local.mk`** (untracked, gitignored):

```sh
cp local.mk.example local.mk
```

- Обязательные: `LLAMA_HOST`, `LLM_NFS_SERVER`.
- Опциональные: `REPO_BASE_URL` (своё Fedora-зеркало),
  `CUDA_DEVEL_SET`/`CUDA_RUNTIME_SET` (точные NEVRA вместо серии),
  `OPENCODE_CONFIG` (конфиг opencode для рестарт-скрипта).
- Без `local.mk` сборка образов работает, `make systemd` — fail-loud.

**Образы** — три ветки, порядок — по зависимостям Makefile:
`llama-cpp-cuda` (runtime-цепь: base → driver → cuda → nccl → runtime),
`kmod` (модули ядра), `nvidia-lact-autoswitch` (LACT).
`all` (целевой по умолчанию) — все ветки + деплой:

```sh
make all
```

Частичная сборка: `make llama-cpp-cuda`, `make kmod`,
`make nvidia-lact-autoswitch`.

**Деплой на хост** (`$(HOST_ROOT)`; входит в `all`):

```sh
make systemd
```

Деплоится: 6 юнитов (`nvidia-kmod`, `nvidia-card-setting`,
`lact-autoswitch`, `llama-cpp`, `llama-cpp-watcher`,
`var-local-llm.mount` — NFS-маунт), скрипты в `/usr/local/bin/`,
sysconfig с дефолтами (OC-параметры, `LLAMA_*`: образ, порт,
`LLAMA_UID`/`LLAMA_MEM`/`LLAMA_SHM_SIZE`), keys `chmod 640`.
`daemon-reload` + `enable` — стек поднимается на боте.

После пересборки driver-стадии (образы kmod/driver/lact):
`systemctl restart nvidia-kmod nvidia-card-setting lact-autoswitch`;
`llama-cpp` — протоколом Этапа 25 (`make llama-cpp-restart
MODE=restart`). Pin `safe` (Этап 27) при этом переживает рестарты
(файл в `/run`). Снятие пина — `rm /run/lact-autoswitch/pin`; если
цикл крахов закончен, также `rm /run/lact-autoswitch/crashes` (иначе
свежее событие в окне 600 c переставит pin).

Эксплуатация живого сервера (эндпоинты, ключи, рестарт-протокол,
память) — `LIVE-SERVER.md`.

## Тесты

```sh
for t in scripts/test-*.sh; do sh "$t" || break; done
python3 scripts/test-lact-autoswitch.py   # LACT-хелпер (TAP)
```
