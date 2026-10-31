# LIVE-SERVER.md

Работа с живым прод-сервером llama-cpp. Читается перед первым действием
над ним: рестарт/стоп/старт, API-ключи, sysconfig, контейнер/юнит,
прод-логи (правило — `AGENTS.md`, секция «Живой сервер (llama-cpp)»).

## Топология и факты

- Роутер: контейнер `llama-cpp` (юнит `llama-cpp.service`), порт 8080
  (`-p ${LLAMA_PORT}:8080`), non-root `-u ${LLAMA_UID}:0` (gid 0
  читает keys `640 root:root` и `/dev/nvidia*` `660 root:root`),
  без `--privileged` (devices: `nvidia0-4` + `nvidiactl` +
  `nvidia-uvm`), `-m ${LLAMA_MEM}` (стартовое 192g: пул cache-ram
  96 GiB (тир 3) + live 2×215k; 160g + пул 128 GiB давал OOM×6 за
  2 дня — 06.09, «Числа» и отчёт Этапа 26 §10),
  `--ulimit memlock=-1:-1` (mlock-модель),
  `--shm-size ${LLAMA_SHM_SIZE}` (1g; NCCL/CUDA IPC ~185M),
  `--models-preset /llama/llama.ini` (маунт `/etc/llama:/llama:ro`).
  Инстанс — единственный потомок pid 1; его порт наружу не
  опубликован: все сигналы — через роутер.
- Сервер одно-модельный (VRAM не позволяет больше): все проверки
  корректны только для него; имя модели параметризуется (`LLAMA_MODEL`,
  по умолчанию `default`, override — `local.mk`). Много-модельный
  сервер — вне скоупа (YAGNI).
- Работа из toolbx: host-нетнс (`127.0.0.1` = loopback хоста), файловая
  система хоста — `/run/host`, systemctl — `chroot /run/host
  /usr/bin/systemctl`, контейнеры — `CRE` (`podman`/`podman-remote`
  по `/run/.containerenv`).
- Эндпоинты роутера (образ a01ce9ffc, с 24.10):
  - `/health` — без ключа (единственный публичный);
  - `/v1/models` — **ключ**; `status.value` (`loaded`) и полные args
    инстанса (доказательство тождества локального контейнера и сервера
    сессии — сверка args);
  - `/slots?model=<M>` — **ключ** (`Authorization: Bearer`):
    `is_processing` на слот — сигнал «инференс в полёте»;
  - `POST /v1/chat/completions` — ключ; verify после рестарта.
- Ключи: файл отдаётся роутеру `--api-key-file` в аргументах юнита
  (инстансу ключ не передаётся отдельно: он на `127.0.0.1` внутри
  контейнера, наружу — только роутер; в образе a01ce9ffc строка
  `api-key-file` в `[*]`-секции `llama.ini` игнорируется — ключи в
   ini не писать). Хостовый `/etc/llama/llama-cpp-keys.txt`
   (mode `640 root:root` — gid 0 читает, контейнер non-root;
   `make systemd` ставит 640 idempotent-шагом; файл с `#`-комментариями
   и пустыми строками; рабочая строка — первая из не-комментариев).
   Читаются в рантайме;
  **не писать в логи/argv** (no-sensitive), без `curl -v` на
  keyed-эндпоинтах.

## SAME_HOST — сессия на этом сервере?

Вердикт **yes**, если все три: (1) какое-то `"baseURL"` в opencode-
конфиге сессии (env `OPENCODE_CONFIG` из `local.mk`, либо поиск:
`opencode.json{,c}` в корне репо → `~/.config/opencode/`) имеет host ∈
{`127.0.0.1`, `localhost`, `::1`} и порт = `LLAMA_PORT`; (2) контейнер
`llama-cpp` запущен в CRE-контексте; (3) его опубликованный порт =
`LLAMA_PORT`.

- **yes** — рестарт остановит нашу сессию (kill + загрузка модели):
  скрипт сам ждёт, пока все слоты `is_processing=false`, и запускается
  только через `make llama-cpp-restart` (setsid).
- **no** — сессия не на этом сервере; **unknown** (конфиг не найден, или
  контейнер/порт не верифицируемы) — консервативно: вести себя как yes.

## Рестарт / стоп / старт

    make llama-cpp-restart MODE=restart [IDLE_TIMEOUT=30] [READY_TIMEOUT=600] [VERIFY_REQUEST=...]
    make llama-cpp-restart MODE=check   # read-only: состояние + SAME_HOST
    make llama-cpp-restart MODE=stop    # wait-idle -> systemctl stop
    make llama-cpp-restart MODE=start   # systemctl start -> ready -> verify

- Self-healing: рецепт гоняет скрипт через `setsid -f` — он переживает
  сессию и таймаут tool-вызова, доводя сервер до готовности. Сессия
  может умереть в процессе рестарта — это по дизайну; координатор
  возвращается и опрашивает status.
- Поток restart: preflight (юнит active/activating — иначе «осознанный
  стоп/обслуживание» и скрипт не трогает; ключи) → wait-idle (все
  слоты `is_processing=false`; таймаут → abort rc=3 **без форса** —
  known-issue stop/restart-hang при in-flight task) → `systemctl
  restart llama-cpp` → wait-ready (`/health` ok + `/v1/models`
  `loaded`) → verify (короткая генерация, `max_tokens=8`).
- rc: 0 ok; 2 preflight/usage/lock; 3 wait-idle (in-flight); 4
  systemctl; 5 wait-ready; 6 verify.
- Состояние: файл `/tmp/llm-rig/llama-cpp-restart.status` — строки
  `<ts> <state> <detail>` (часы — MSK (UTC+3)); states: `start` (с pid),
  `preflight`, `same-host`, `wait-idle`, `restarting`/`stopping`/`starting`,
  `check`, `wait-ready`, `verifying`; финальная строка `done rc=0` /
  `failed rc=<N> <reason>`. Лог — `/tmp/llm-rig/llama-cpp-restart.log`.
  Опрос координатором: повторное чтение файла между шагами, до финальной
  строки.

## Взаимодействие с юнитом / watcher

- `llama-cpp.service`: `Restart=always`, `RestartSec=30`,
  `ExecStartPre=-podman rm -f` (новый контейнер на каждом рестарте).
- `llama-cpp-watcher.sh`: kill контейнера по zombie-сигнатурам
  (`CUDA error: an illegal memory access`, `CUDA error: an internal
  operation failed`); cooldown 120 s; неактивный юнит — skip
  («осознанный стоп»).
- Смена образа: `LLAMA_IMAGE` в `/etc/sysconfig/llama-cpp`
  (`make systemd` регенерирует) → следующий рестарт поднимет новый
  образ.

## Числа

Заполнить после live-окна (отчёт `docs/superpowers/reports/`
Этапа 25). Каждое время — **с длиной контекста (prompt-токены) на
момент измерения**: длительность префилла зависит от глубины
контекста (не строго линейно).

Замеры 02.09 (live-окно Этапа 25, отчёт
`docs/superpowers/reports/2026-09-02-stage25-safe-restart.md`; модель
30 GB q8, mlock, 5×GPU tensor split; модель — NFS4.2 `<NFS>:
/mnt/sas/llm` (TrueNAS), клиент pigoky 10GbE, `/models` = bind
`/var/local/llm/gguf-models`):

- t0→t1 даунтайм (старт рестарта → первый `/health` ok): **137 s**
  (включает stop-hang 90 s → SIGABRT и упавший старт №1 exit 125 +
  RestartSec 30 — known-issue stop/restart-hang; запросов в окне нет).
  Контейнер-старт → listen роутера — ~1 s.
- t1→t2 загрузка модели (→ `/v1/models` `loaded`): **21 s** (тёплый
  клиентский page cache: dd 1 GB @ 6.2 GB/s; чистая NFS4.2 —
  436 MB/s → cold ≈ 70–80 s на 30 GB; запросов ещё нет).
- t3 verify (200, tok/s): prompt **58 токенов** — prefill 55.90 t/s
  (1038 ms), генерация 8 токенов 17.30 t/s (405 ms, холодные CUDA
  graphs, `graphs reused = 2`); total 1442 ms.
- Ре-префилл первого запроса сессии после рестарта (cache-ram пуст):
  **117645 prompt-токенов → 181.2 s (649.23 t/s, 1.54 ms/токен)**;
  полный ход сессии (＋6159 токенов генерации @ 45.29 t/s) — 317 s.

Замеры 03.09 (live-окно Этапа 26, отчёт
`docs/superpowers/reports/2026-09-03-stage26-llama-cpp-nonroot.md`;
non-root-контейнер, лимит `LLAMA_MEM=120g`, та же модель):

- t0→t1 даунтайм: **106 s** (слоты idle, без stop-hang); t1→t2
  загрузка модели (cold NFS): **89 s**; verify keyed POST — 2 s.
- Память: `podman stats` ≈ anon+shmem (file-кэш не входит); cgroup
  `memory.current` = anon+file+shmem. `file` = 29.9 GiB константа
  (page cache модели, NFS). `anon` — скачками с сессионным трафиком
  (cache-ram/KV), потом плато: stats 7.9 → 13.3 → 26.9 GB (16:52→17:25),
  далее плато (~+0.3 GiB/40 мин). Пик окна: cg 51.0 GiB =
  42% лимита 120 GiB. OOM-точек нет; `LLAMA_MEM` — зона оператора.
- Post-окно (19:01): при активной сессии cgroup уперся в потолок
  120g (anon 111.9 GiB = pool 128-пол + KV слотов, file-кэш модели
  рекалмится 29.9→7.8 GiB как кушон, OOM нет). 19:40 оператор:
  `LLAMA_MEM=160g` (worst case pool+KV+shmem ≈ 150); рестарт 19:43 —
  102+24 s (тёплый NFS), `memory.max=171798691840`.

Замеры 06.09 (OOM-анализ при 160g; полный разбор — отчёт Этапа 26
§10, `docs/superpowers/reports/2026-09-03-stage26-llama-cpp-nonroot.md`):

- 6 cgroup-OOM-киллов инстанса (04.09 ×2, 05.09 ×2, 06.09 ×2) —
  контейнер (роутер) во всех случаях выживал, респаунил инстанс;
  watcher не срабатывал (zombie-сигнатуры в логе нет).
- Состав килла: `usage = limit = 160 GiB`; anon 158 GiB =
  cache-ram 128 GiB (полный) + ~28 GiB (KV 2 слотов + scratch
  префиллов + checkpoint'и) + shmem/file/kernel ~5 GiB.
- KV-ставка (q8_0): ~122 MiB/1k токенов → 215k-слот ≈ 25 GiB;
  структурный потолок конфига 128 + 2×215k + прочее ≈ 188 GiB >
  160g — OOM при одновременном префилле двух крупных сессий.
- Цена OOM: ~6 мин деградации (загрузка модели + полные ре-префиллы
  обеих сессий 285 + 243 s), клиентам 500.
- Пул квантован по сессиям (тиры): T1 32 GiB → лимит 80g;
  T2 64 GiB → 160g; T3 (3-я сессия рабочая) 96 GiB → 192g.
- Решение 06.09: `LLAMA_MEM=192g` + `cache-ram=98304` (T3);
  max ~152 GiB, запас ~40 GiB; host-sysconfig — вручную
  (sysconfig-gen: значение файла сильнее `--default`).

## Логи

- `AGENTS.md`, секция «Логи llama-server (llama-cpp)» (таймстемпы
  `мм.сс.ммм.ммм`, префикс `[NNNNN]` = порт instance, нумерация task).
- Постоянная история: `journalctl -lu llama-cpp [--since ...]` (вывод
  сервера уходит в журнал юнита; watcher работает по нему).
- `podman-remote logs llama-cpp` — только текущий контейнер
  (`ExecStartPre` удаляет контейнер — история не накапливается).
