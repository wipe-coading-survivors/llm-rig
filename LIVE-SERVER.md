# LIVE-SERVER.md

Работа с живым прод-сервером llama-cpp. Читается перед первым действием
над ним: рестарт/стоп/старт, API-ключи, sysconfig, контейнер/юнит,
прод-логи (правило — `AGENTS.md`, секция «Живой сервер (llama-cpp)»).

## Топология и факты

- Роутер: контейнер `llama-cpp` (юнит `llama-cpp.service`), порт 8080
  (`-p ${LLAMA_PORT}:8080`), `--models-preset /root/llama/llama.ini`.
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
- Эндпоинты роутера:
  - `/health` — без ключа;
  - `/v1/models` — без ключа; `status.value` (`loaded`) и полные args
    инстанса (доказательство тождества локального контейнера и сервера
    сессии — сверка args);
  - `/slots?model=<M>` — **ключ** (`Authorization: Bearer`):
    `is_processing` на слот — сигнал «инференс в полёте»;
  - `POST /v1/chat/completions` — ключ; verify после рестарта.
- Ключи: хостовый `/etc/llama/llama-cpp-keys.txt` (файл с `#`-
  комментариями и пустыми строками; рабочая строка — первая из
  не-комментариев). Читаются в рантайме; **не писать в логи/argv**
  (no-sensitive), без `curl -v` на keyed-эндпоинтах.

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
`docs/superpowers/reports/2026-09-02-stage25-safe-restart.md`; 27B q8,
mlock, 5×GPU tensor split, page cache тёплый):

- t0→t1 даунтайм (старт рестарта → первый `/health` ok): **137 s**
  (включает stop-hang 90 s → SIGABRT и упавший старт №1 exit 125 +
  RestartSec 30 — known-issue stop/restart-hang; запросов в окне нет).
  Контейнер-старт → listen роутера — ~1 s.
- t1→t2 загрузка модели (→ `/v1/models` `loaded`): **21 s** (запросов
  ещё нет).
- t3 verify (200, tok/s): prompt **58 токенов** — prefill 55.90 t/s
  (1038 ms), генерация 8 токенов 17.30 t/s (405 ms, холодные CUDA
  graphs, `graphs reused = 2`); total 1442 ms.
- Ре-префилл первого запроса сессии после рестарта (cache-ram пуст):
  **117645 prompt-токенов → 181.2 s (649.23 t/s, 1.54 ms/токен)**;
  полный ход сессии (＋6159 токенов генерации @ 45.29 t/s) — 317 s.

## Логи

- `AGENTS.md`, секция «Логи llama-server (llama-cpp)» (таймстемпы
  `мм.сс.ммм.ммм`, префикс `[NNNNN]` = порт instance, нумерация task).
- Постоянная история: `journalctl -lu llama-cpp [--since ...]` (вывод
  сервера уходит в журнал юнита; watcher работает по нему).
- `podman-remote logs llama-cpp` — только текущий контейнер
  (`ExecStartPre` удаляет контейнер — история не накапливается).
