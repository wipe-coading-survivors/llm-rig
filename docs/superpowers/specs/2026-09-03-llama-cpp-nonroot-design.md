# Спека: llama-cpp non-root (Этап 26)

- Дата: 03.09.2026
- Статус: раунд 1 (03.09.2026): дизайн утверждён; **`LLAMA_MEM=120g` —
  стартовое значение, без A/B** (решение пользователя 03.09.2026:
  потребление растёт с накопленным трафиком без плато-гарантии, «с каждым
  расчётом размер только увеличивается» — при OOM оператор сам выставит
  нужное значение в sysconfig)
- Источник: `TODO.md`, Этап 26 (решение 03.09: откат на root
  build/deploy/debug; из «Non-root окружения» остаётся только запуск
  контейнера `llama-cpp` non-root)
- Основа: брейншторм 03.09.2026 + live-верификация фактов F1–F16 на
  хосте (toolbx, CRE=podman-remote)
- Связь: после ревью — план (writing-plans) → SDD → live-окно →
  finishing (merge в `main`)

## Контекст

Прод-контейнер `llama-cpp` (юнит `llama-cpp.service`) сейчас
`--privileged` + root: привилегии дают весь `/dev` (включая
`nvidiactl`/`nvidia-uvm`/`nvidia-caps`), bypass seccomp/apparmor,
неограниченный memlock и доступ к `/root`. Решение 03.09: снять
`--privileged`, запускать контейнер от `-u ${LLAMA_UID}:0` (gid 0 =
root-группа хоста — она же читает `/dev/nvidia*` `660 root:root` и
keys `640 root:root`), ограничить память `-m` и memlock явным ulimit.
Containerfile — без изменений (`/app` уже 755, F2).

## Цель

1. `resources/llama/llama-cpp.service`: non-root запуск без
   `--privileged` (devices, `-u`, `-m`, `--ulimit memlock`, маунт
   `/etc/llama:/llama:ro`, `--models-preset /llama/llama.ini`).
2. `Makefile` (`systemd`): sysconfig-дефолты `LLAMA_UID`, `LLAMA_MEM`,
   `LLAMA_SHM_SIZE=1g`; idempotent `chmod 640` keys.
3. Рипл live ini: `api-key-file=/llama/...` (host-файл) + debug-
   скрипты, живущие с live ini.
4. Пины: `test-systemd-units.sh`, `test-makefile-graph.sh`,
   `test-debug-scripts.sh`; `LIVE-SERVER.md` (топология + цифры).
5. Live-окно: деплой с `LLAMA_MEM=120g` + приёмка (id non-root,
   keyed-эндпоинты, GPU/model-load, memlock, shm) + замеры памяти
   (baseline при пустом пуле + динамика; F8/F16: потребление растёт с
   накопленным трафиком — OOM при заполнении пула на 120g ожидаем и
   задокументирован, не отказ этапа).

## Не цели (отменено решением 03.09)

- non-root build/deploy/debug (rootful toolbx остаётся);
- привилегии через `sudo`; container-registry (ghcr/локальный);
- containerfile (без изменений, F2);
- `lact-autoswitch` (остаётся `--privileged`);
- watcher, `llama-cpp-restart.sh` (без изменений — работают по
  юниту/HTTP, не зависят от user контейнера);
- `nvidia-uvm-tools` в `--device` (в open-fds инстанса не был, F4).

## Верифицированные факты (основания дизайна, 03.09.2026)

| # | Факт |
|---|---|
| F1 | Live-контейнер: `User=` (root), `Privileged=true`, `ShmSize=68719476736` (64g) — `podman-remote inspect llama-cpp` |
| F2 | `/app` в образе `llama-cpp-cuda:13.3` = `755 root:root` → non-root исполнит `/app/llama-server`; containerfile без изменений |
| F3 | Хост: `/dev/nvidia0-4`, `nvidiactl`, `nvidia-uvm`, `nvidia-uvm-tools` = `660 root:root`; `/dev/nvidia-caps/` = `755`, `nvidia-cap1..4` = `440 root:root` |
| F4 | Open-fds инстанса (`/proc/34/fd`): `nvidia0-4` (rw), `nvidiactl` (rw), `nvidia-uvm` (rw), `nvidia-caps/nvidia-cap1`, `nvidia-caps/nvidia-cap2` (r); `nvidia-uvm-tools` не открыт |
| F5 | Проба (одноразовый `--rm` контейнер, не трогая live): `-u 1001001:0` + только `--device nvidiactl/nvidia0/nvidia-uvm` + `label=disable`, без privileged → `nvidia-smi` работает (GPU0, 12288 MiB); `id` = `uid=1001001(1001001) gid=0(root)`; `HOME=/app` (нет passwd-записи → podman ставит HOME=WORKDIR) |
| F6 | `/dev/shm`: 185M занято из 64G (NCCL/CUDA IPC) → `1g` достаточно |
| F7 | Хост RAM: 252 GiB (`MemTotal 263982244 kB`) |
| F8 | Потребление host RAM контейнера **растёт с накопленным трафиком и не гарантированно возвращается вниз**: `podman stats` 03.09 — 143.5 GB в 09:5x → 211.7 GB к ~10:1x → плато **212.5 GB** (0.00 GB/60 s) при `cache-ram=131072` (128 GiB пул KV заполняется сессиями; эвикшенов за 6 ч до замера — 0); для сравнения, 09.02 (отчёт cache-ram): 3 крупные сессии = RSS 92.8 GB. Т.е. «steady-state» = f(накопленных сессий от последнего рестарта); 160g при текущей нагрузке (212.5 GB) не выдержит, при нагрузке уровня 09.02 — с запасом |
| F16 | Точность показаний: `podman stats` MEM USAGE = cgroup `memory.current` (совпало при сверке: 211.7 GB vs 210.0 GB в момент замера) — расхождение с «143.5 GB» было движением потребления, а не неточностью. Состав: `machine.slice/libpod-<id>.scope/memory.stat` — **anon ≈ 99%** (сейчас 193/195 GiB), file ~2 GiB; anon = mlock-модель + KV-пул + host-буферы (не сжимается cgroup-лимитом) |
| F9 | Host `/etc/sysconfig/llama-cpp`: `LLAMA_IMAGE=llama-cpp-cuda:13.3`, `LLAMA_LOG_TIMESTAMPS=1`, `LLAMA_PORT=8080`, `LLAMA_SHM_SIZE=64g`; `LLAMA_UID`/`LLAMA_MEM` отсутствуют. `sysconfig-gen --default` существующее значение **не** перезаписывает → one-shot мигрейшн `64g→1g` нужен отдельно |
| F10 | Live `/etc/llama/llama.ini` (host-файл, не в репо): `api-key-file = /root/llama/llama-cpp-keys.txt`, `ctx-size=430000`, `load-mode=mlock`, `cache-ram=131072` → после смены маунта на `/llama` строка `api-key-file` должна стать `/llama/llama-cpp-keys.txt` |
| F11 | `/etc/llama/llama-cpp-keys.txt` = `600 root:root`; `/etc/llama` = `755` → `chmod 640` даёт чтение gid 0 (container-user `1001001:0`) |
| F12 | NFS-модели: `/var/local/llm/gguf-models` = `755`, gguf-файлы `644` (NFS, group UNKNOWN) → non-root читает |
| F13 | `debug/llama-run.sh` — mirror юнита (root, `--privileged`, маунт `/root/llama`, live ini); C2-launch в `debug/repro-llama-block3-run.sh` — live ini через маунт `/root/llama`; стубы (plain: явный `--api-key-file /root/llama/...`, router: свой `debug/llama-cpu-stub.ini`) live ini **не** используют |
| F14 | Пины: `scripts/test-systemd-units.sh:173` (`-v /etc/llama:/root/llama:ro`), `scripts/test-makefile-graph.sh:926` (`LLAMA_SHM_SIZE=64g`), `scripts/test-debug-scripts.sh` (строки маунтов llama-run/repro) |
| F15 | Graph-тест `make systemd` ходит во временный hostroot **без** `/etc/llama` → keys-chmod-шаг в Makefile должен не падать при отсутствии файла (guard) |

## Дизайн

### 1. `resources/llama/llama-cpp.service`

`ExecStart` (единственная changed-секция; `[Unit]`/`Restart`/`Install`
без изменений):

```
ExecStart=/usr/bin/podman run \
    --name llama-cpp \
    --device /dev/nvidia0 \
    --device /dev/nvidia1 \
    --device /dev/nvidia2 \
    --device /dev/nvidia3 \
    --device /dev/nvidia4 \
    --device /dev/nvidiactl \
    --device /dev/nvidia-uvm \
    --security-opt label=disable --shm-size=${LLAMA_SHM_SIZE} \
    -u ${LLAMA_UID}:0 \
    -m ${LLAMA_MEM} \
    --ulimit memlock=-1:-1 \
    -v /var/local/llm/gguf-models:/models \
    -v /etc/llama:/llama:ro \
    -p ${LLAMA_PORT}:8080 \
    -e LLAMA_LOG_TIMESTAMPS=${LLAMA_LOG_TIMESTAMPS} \
    ${LLAMA_IMAGE} --port 8080 --host 0.0.0.0 \
    --models-preset /llama/llama.ini --metrics
```

Изменения против текущего: **снят** `--privileged`; **добавлены**
`--device /dev/nvidiactl`, `--device /dev/nvidia-uvm` (F3/F4: без
privileged остаются только явные `--device`), `-u ${LLAMA_UID}:0`
(gid 0 — F3/F11), `-m ${LLAMA_MEM}`, `--ulimit memlock=-1:-1`
(`load-mode=mlock`, F10); маунт `/root/llama` → `/llama`,
`--models-preset` → `/llama/llama.ini` (F10: non-root не видит `/root`).

`nvidia-caps`/`uvm-tools` — не добавляем (R1: только fallback).

### 2. `Makefile` (таргет `systemd`)

- sysconfig-gen `llama-cpp`: `--default LLAMA_UID=1001001`,
  `--default LLAMA_MEM=120g` (стартовое значение; решение 03.09 —
  при OOM оператор сам выставляет нужное в host sysconfig, F8),
  `--default LLAMA_SHM_SIZE=64g` → `1g` (F6).
- Keys chmod (idempotent, guard по F15; путь из существующей
  `$(LLAMA_KEYS_FILE)`):

```
if [ -f $(HOST_ROOT)$(LLAMA_KEYS_FILE) ] ; then \
    chmod 640 $(HOST_ROOT)$(LLAMA_KEYS_FILE) ; \
fi
```

- One-shot `LLAMA_SHM_SIZE=64g→1g` в существующий host sysconfig (F9)
  — **не** в Makefile (рецепт чистый; `--default` не должен нести
  мигрейшн): шаг live-окна §7.3.

### 3. Host-изменения (live-окно, файлы вне репо)

- `/etc/llama/llama.ini`: `api-key-file = /llama/llama-cpp-keys.txt`
  (F10).
- `/etc/sysconfig/llama-cpp`: one-shot
  `sed -i 's/^LLAMA_SHM_SIZE=64g$/LLAMA_SHM_SIZE=1g/'` (F9);
  `LLAMA_UID`/`LLAMA_MEM` — добавляет `make systemd` (новые ключи).
- `/etc/llama/llama-cpp-keys.txt`: `chmod 640` (шаг `make systemd`).

### 4. Debug-скрипты (рипл live ini, F13)

- `debug/llama-run.sh` — **полный mirror нового юнита**: те же
  devices (0-4 + nvidiactl + nvidia-uvm), `--security-opt
  label=disable --shm-size=1g`, `-u 1001001:0 -m 120g`, `--ulimit
  memlock=-1:-1`, маунт `/etc/llama:/llama:ro`,
  `--models-preset /llama/llama.ini` (значения зашиты — стиль файла;
  CRE-detection и `rm -f`/`--name` как есть). Header-заявка «manual
  fallback for the unit» сохраняется истинной.
- `debug/repro-llama-block3-run.sh` — только C2-launch (live ini):
  маунт `/etc/llama:/llama:ro` + `--models-preset /llama/llama.ini`
  (остаётся `--privileged` — debug-контейнер). Стубы (plain/router) —
  без изменений (свой ini / явные args, root).
- `debug/llama.ini` — **не трогаем**: не используется ни в одном
  скрипте (0 ссылок), значения расходятся с live ini — артефакт;
  `api-key-file=/root/llama/...` в нём согласован с root-контейнерами,
  которые его (потенциально) бы читали.

### 5. Тесты

- `scripts/test-systemd-units.sh` (секция llama):
  - маунт: `-v /etc/llama:/root/llama:ro` → `-v /etc/llama:/llama:ro`;
  - новые пины: `-u ${LLAMA_UID}:0`, `-m ${LLAMA_MEM}`,
    `--ulimit memlock=-1:-1`, `--device /dev/nvidiactl`,
    `--device /dev/nvidia-uvm`, `--models-preset /llama/llama.ini`;
  - негативный: llama-юнит без `--privileged` (autoswitch остаётся
    privileged — пин только по `llama-cpp.service`; существующий
    autoswitch-пин `--privileged` не трогать).
- `scripts/test-makefile-graph.sh`:
  - `LLAMA_SHM_SIZE=64g` → `1g` (F14);
  - новые syscfg-пины: `LLAMA_UID=1001001`, `LLAMA_MEM=120g`;
  - keys chmod: до `make systemd` создать в hostroot тесте
    `etc/llama/llama-cpp-keys.txt` mode `600` → после таргета
    assert mode `640` (позитивный кейс guard'а §2).
- `scripts/test-debug-scripts.sh`: llama-run mount → `/llama:ro`
  (count 1); repro: C2 → `/llama:ro` (count 1) + стубы `/root/llama:ro`
  (count 2, без изменений — F13); новые пины mirror-флагов
  llama-run.sh (`-u 1001001:0`, `-m 120g`, `--ulimit memlock=-1:-1`,
  `nvidiactl`/`nvidia-uvm`, `--models-preset /llama/llama.ini`).
- Остальные тесты (`test-llama-cpp-restart.sh`,
  `test-llama-cpp-watcher.sh`, `test-no-sensitive.sh`, ...) — без
  изменений, должны остаться зелёными.

### 6. `LIVE-SERVER.md`, `TODO.md`

- `LIVE-SERVER.md`:
  - «Топология»: non-root `-u 1001001:0` (gid 0 читает keys `640` и
    `/dev/nvidia*` `660`), без `--privileged` (devices 0-4 + nvidiactl
    + uvm), `-m ${LLAMA_MEM}`, `--ulimit memlock=-1:-1`, маунт
    `/llama` + preset, shm `1g` (F6: 185M NCCL/CUDA IPC);
  - «Ключи»: mode `640 root:root` (gid 0 читает);
  - «Числа»: замеры §7 (baseline при пустом пуле, динамика, разбор
    `memory.stat` anon/file; F8/F16: рост с накопленным трафиком).
- `TODO.md`: чекбоксы Этапа 26, ссылка на отчёт, `LLAMA_MEM=120g`
  (стартовое; оператор поднимает при OOM).

### 7. Live-окно (после SDD-реализации)

1. Pre: снимки (`inspect`, sysconfig, ini, keys mode, `git status`
   ветки), `make llama-cpp-restart MODE=check` (SAME_HOST=yes).
2. Deploy: `make systemd` → проверка: unit на хосте (diff против
   resources/), sysconfig (`LLAMA_UID`, `LLAMA_MEM`, `SHM` — см. 3),
   keys mode `640`.
3. Host-правки: one-shot sed `64g→1g` (F9), ini `api-key-file`
   (F10). Проверка: `grep LLAMA_SHM_SIZE` = `1g`, `grep api-key-file`.
4. `LLAMA_MEM=120g` (sysconfig уже из шага 2; A/B отменено решением
   03.09): `MODE=restart` → ready → приёмка:
   - `podman-remote exec llama-cpp id` = `uid=1001001 gid=0`;
   - keyed-эндпоинты: `/slots` (Bearer) + verify POST 200;
   - GPU/model-load: `/v1/models` `loaded`, tensor-split 5×,
     args-сверка (тождество контейнера);
   - memlock: `Max locked memory` = `unlimited` в
     `/proc/1/limits` (pid 1 контейнера = ulimit контейнера; PID-
     неймспейс свой — host pid не использовать);
   - shm: `df /dev/shm` = `1.0G`;
   - память (F8/F16): `podman stats` + cgroup
     `machine.slice/libpod-<id>.scope/memory.{current,stat}` — baseline
     сразу после ready (пустой пул: mlock-модель + host-буферы +
     re-префилл нашей сессии) и динамика через интервалы окна (рост с
     трафиком — ожидаемо, не дефект);
   - сессия переживает рестарт (написание отчёта = приёмка).
5. OOM на 120g (ожидан по F8 при накоплении трафика; возможно и в окне):
   зафиксировать oom-строки `journalctl` + `memory.current` в момент
   падения → поднять `LLAMA_MEM` в host sysconfig (операторское
   значение по факту) → `MODE=restart` → продолжить/завершить
   приёмку. Не отказ этапа: финальное значение — зона оператора
   (решение 03.09).
6. Финал: отчёт `docs/superpowers/reports/2026-09-0X-stage26-llama-cpp-
   nonroot.md` (замеры, OOM-точка если была); `LIVE-SERVER.md` «Числа»
   + «Топология»; `TODO.md` (чекбоксы, `LLAMA_MEM=120g`).
7. Статика: полный тест-сьют зелёный.

## Риски и митигации

| # | Риск | Митигация |
|---|---|---|
| R1 | `nvidia-caps/nvidia-cap1,2` = `440 root:root` (F3): открыты в текущем инстансе (F4), non-root их не откроет; нужны ли они для полного CUDA-контекста — неизвестно (проба F5 — уровень `nvidia-smi`) | Live-окно решающий: приёмка GPU/model-load на 120g. Fallback: one-shot/udev `chmod 640 root:root` host-nodes cap1/2 + `--device /dev/nvidia-caps/nvidia-cap1|2` в юнит (+пины) — пост-оконным коммитом |
| R2 | `--privileged` bypass'ил seccomp/apparmor; non-privileged контейнер под default-профилями — CUDA/NCCL может упереться в syscall | Стандартный non-privileged NVIDIA-сетап работает под default seccomp (конвенция nvidia-container); live-окно решающий. Fallback: `--security-opt seccomp=unconfined` (и/или `apparmor=unconfined`) — изоляция слабее, фикс в отчёте |
| R3 | OOM на `120g` (юнит `Restart=always`, `RestartSec=30` → crash loop) — ожидаем при накоплении трафика (F8), возможно и в окне | Протокол §7.5: oom-строки + замер → `MODE=stop` → поднять `LLAMA_MEM` в host sysconfig → `MODE=restart`; watcher не реагирует (нет zombie-сигнатур) |
| R4 | `HOME=/app` не writable для non-root (F5) → nvJitLink cache-варнинг | Не фатально: cubin'ы для arch 86 в бандле (F2/образ); наблюдение по логу в окне. Если станет проблемой — `-e HOME=/tmp` в юнит |
| R5 | Сессия координатора умирает на рестарте окна | По дизайну (Этап 25): `setsid -f` + status-файл; координатор опрашивает status |
| R6 | Пропущен one-shot `64g→1g` (F9) → юнит молча держит 64g (не падает, только перерасход) | Шаг §7.3 с явной проверкой `grep LLAMA_SHM_SIZE` |
| R7 | `LLAMA_MEM=120g` — стартовое; при накоплении трафика (F8) лимит будет упирается: OOM | По решению 03.09 — зона оператора: поднять `LLAMA_MEM` в host sysconfig + `make systemd`/`MODE=restart`; дефолт Makefile меняется отдельным решением (пост-оконным коммитом правятся дефолт + пины graph-теста/`debug/llama-run.sh` + `LIVE-SERVER.md`) |

## Критерии готовности

- Файлы: `resources/llama/llama-cpp.service`, `Makefile` (3
  sysconfig-дефолта + keys-chmod guard), `debug/llama-run.sh`,
  `debug/repro-llama-block3-run.sh` (C2),
  `scripts/test-systemd-units.sh`, `scripts/test-makefile-graph.sh`,
  `scripts/test-debug-scripts.sh`, `LIVE-SERVER.md`, `TODO.md`, отчёт;
  containerfile — без изменений (F2);
- тест-сьют зелёный (все существующие + обновлённые пины);
- live-окно: приёмка по протоколу §7: `id` non-root, keyed-эндпоинты,
  GPU/model-load, memlock unlimited, shm 1g, замеры памяти (baseline +
  динамика, F8/F16), сессия пережила рестарт; OOM на 120g — задокументирован
  (не отказ этапа, R3/R7);
- `TODO.md` Этап 26: чекбоксы отмечены, `LLAMA_MEM=120g`;
- finishing: merge ветки в `main`.
