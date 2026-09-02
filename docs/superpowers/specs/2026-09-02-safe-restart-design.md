# Спека: безопасный рестарт живого сервера llama-cpp (Этап 25)

- Дата: 02.09.2026
- Статус: черновик (ожидает ревью)
- Источник: `TODO.md`, Этап 25 (фоллоу-ап live-окна Этапа 24; урок `nohup` —
  отчёт `docs/superpowers/reports/2026-09-02-stage24-cuda-repo.md` §5)
- Основа: брейншторм 02.09.2026 (дизайн утверждён пользователем) + live-
  верификация фактов F1–F12 на хосте `pigoky` (toolbx `t-ocode`)
- Связь: после ревью — план (writing-plans) → SDD → live-окно →
  finishing (merge в `main`)

## Контекст

Live-окно Этапа 24 рестартировало прод-контейнер вручную: сессию
координатора opencode держал тот же сервер, рестарт пришлось выполнить
после завершения хода координатора, а отложенный рестарт через
`nohup ... &` выжил случайно (отчёт §5: по таймауту tool-вызова opencode
nohup-процесс может быть убит). Скрипта, определения «сервер сессии
работает на этом хосте» и доков по работе с живым сервером (ключи,
sysconfig, watcher, даунтайм) нет. Этап 25 закрывает это.

## Цель

1. `scripts/llama-cpp-restart.sh` + таргет `make llama-cpp-restart`:
   рестарт/стоп/старт живого llama-cpp-сервера из opencode-сессии, которую
   обслуживает тот же сервер. Self-healing: запуск через `setsid -f` —
   скрипт доживает до готовности сервера независимо от сессии/инструмент-
   вызова (урок nohup).
2. `LIVE-SERVER.md` (корень репо, tracked, без секретов): как работать с
   живым сервером. Подтягивается read-on-demand по **деятельностному**
   триггеру (правило в `AGENTS.md`), а не по «загружен ли скилл» / «в окне
   ли мы» — оба ненадёжны: суб-агент стартует со свежим контекстом и не
   видит скилл-состояние координатора; «окно» — фаза, объявленная планом,
   а не машинно-определяемое состояние.
3. `local.mk` — без новых переменных (анализ §4, решение пользователя
   02.09.2026: не раздувать).
4. Live-окно: in-flight-тест (abort) + полный рестарт с замером таймлайна;
   приёмка — сессия переживает рестарт.

## Не цели

- Vendor-патч llama.cpp (known-issue «stop/restart-hang при in-flight
  task» из архива): здесь только верификация, что рестарт **после idle**
  не виснет; закрытие пункта «Перенесено из архива» — отдельное решение по
  результатам live-окна.
- Изменения watcher/юнитов/sysconfig-gen — только правила взаимодействия.
- Ollama/jupyter (этапы 21/22), non-root (этап 26).

## Верифицированные факты (основания дизайна, 02.09.2026)

| # | Факт |
|---|---|
| F1 | Сессию обслуживает сервер из глобального opencode-конфига `~/.config/opencode/opencode.jsonc` (вне репо, машинно-локальный): provider `local-llama-cpp`, `baseURL http://127.0.0.1:8080/v1`; модель `default` (алиасы high/low/medium используют SDD-агенты) |
| F2 | toolbx в host-нетнсе (нет своего veth; `hostname -I` = адреса хоста) → `127.0.0.1` из toolbx = loopback хоста. Hostname контейнера `toolbx`, хоста `pigoky` → hostname-сравнение ненадёжно и **не используется** |
| F3 | `CRE=podman-remote` контекст = тот же хост: `podman-remote ps` видит контейнер `llama-cpp` (`llama-cpp-cuda:13.3`, Up) |
| F4 | Порт инстанса (35119 — из args в `/v1/models`) наружу не опубликован; сигналы — только через роутер :8080 |
| F5 | `/health` (без ключа) — уровень роутера, `{"status":"ok"}`; достаточность как ready-gate **не верифицирована** (без рестарта не проверить) → ready-gate = F6 + verify; семантику уточнит live-окно |
| F6 | `/v1/models` (без ключа): модель `default`, `status.value="loaded"`, полные args инстанса → ready-gate + доказательство тождества локального контейнера и сервера сессии (сверка args) |
| F7 | `/slots?model=default` (нужен Bearer-ключ): `is_processing` (bool) и `id_task` на слот; между LLM-вызовами слоты idle (проверено: слоты нашей сессии — 42k prompt-токенов, `is_processing=false`); суб-агенты генерят параллельно на том же сервере → wait-idle — реальный шаг |
| F8 | Ключи: хостовый `/etc/llama/llama-cpp-keys.txt` (из toolbx — `/run/host/...`); файл с `#`-комментариями и пустыми строками; парсинг = первая строка, не комментарий/пустая; `--api-key-file` сервер их принимает (отчёт §5) |
| F9 | Юнит `llama-cpp.service`: `ExecStartPre=-podman rm -f`, `-p ${LLAMA_PORT}:8080`, `Restart=always`, `RestartSec=30`, `EnvironmentFile=/etc/sysconfig/llama-cpp` (`LLAMA_IMAGE` — build; `LLAMA_PORT`, `LLAMA_SHM_SIZE`, `LLAMA_LOG_TIMESTAMPS` — default) |
| F10 | `llama-cpp-watcher.sh`: kill контейнера по zombie-сигнатуре; skip неактивного юнита (конвенция «осознанный стоп/обслуживание»); cooldown 120 s |
| F11 | Makefile уже несёт `LLAMA_HOST ?= 127.0.0.1`, `LLAMA_PORT ?= 8080`, `LLAMA_URL`, `SYSTEMDCTL` (chroot `$(HOST_ROOT)` при toolbx), `LLAMA_CPP = llama-cpp`; sysconfig `lact-autoswitch` уже использует дефолты `LLAMA_MODEL=default` и `LLAMA_KEYS_FILE=/etc/llama/llama-cpp-keys.txt` — концепции существуют как проектные конвенции |
| F12 | В toolbx доступны: bash, curl, jq, python3, flock, `setsid -f` (always fork) |

## Дизайн

### 1. Правило SAME_HOST (preflight скрипта)

Все три условия:

1. хотя бы одно значение `"baseURL"` в opencode-конфиге
   (`$HOME/.config/opencode/opencode.json{,c}`; извлечение всех значений
   grep'ом — JSON-парсер не нужен: конфиг машинно-локальный, формат
   стабилен) имеет host ∈ {`127.0.0.1`, `localhost`, `::1`} и порт =
   `LLAMA_PORT`;
2. контейнер `$(LLAMA_CPP)` запущен в CRE-контексте;
3. опубликованный порт контейнера (`$(CRE) inspect`) = `LLAMA_PORT`.

Вердикты:

- **SAME_HOST=yes** — сессию держит этот сервер: рестарт остановит сессию
  (kill + загрузка модели). wait-idle обязателен; запуск — только
  self-healing (setsid, §2).
- **SAME_HOST=no** — сессия не на этом сервере: продолжаем, заметка в
  status.
- **unknown** (опencode-конфиг не найден/не распознан) — консервативно:
  вести себя как yes (wait-idle + setsid), заметка в status.

### 2. `scripts/llama-cpp-restart.sh`

bash, `set -u` (конвенция watcher). Значения — из env (выставляет
Makefile-таргет) либо дефолты: `CRE` (правило `no-cre-hardcode`: `podman`
+ `-remote`, если существует `/run/.containerenv`), `HOST_ROOT`
(`/run/host`, если существует `/run/.containerenv`, иначе пусто —
конвенция Makefile), `SYSTEMDCTL` (аналогично Makefile), `LLAMA_URL`,
`LLAMA_MODEL` (дефолт `default`), `LLAMA_KEYS_FILE` (дефолт
`/etc/llama/llama-cpp-keys.txt` — путь **на хосте**; из toolbx читается
как `$HOST_ROOT$LLAMA_KEYS_FILE`), `LLAMA_CONTAINER`/`LLAMA_UNIT`
(дефолт `llama-cpp`), `STATUS` (дефолт
`/tmp/llm-rig/llama-cpp-restart.status`).

Режимы: `check` | `restart` | `stop` | `start`. Параметры:
`--idle-timeout N` (дефолт 30 c), `--ready-timeout N` (дефолт 600 c),
`--model M`, `--verify-request TEXT` (дефолт — короткая фраза).

Конкурентность: `flock -n` на STATUS-файле — второй запуск abort
(один операторский запуск за раз).

Коды возврата:

| rc | смысл |
|---|---|
| 0 | режим завершён |
| 2 | preflight: юнит не active/activating (restart/stop), контейнер не Up, ключи нечитаемы, сервер недоступен |
| 3 | wait-idle: таймаут — инференс в полёте; abort **без** форса (known-issue stop/restart-hang при in-flight task) |
| 4 | `$SYSTEMDCTL restart` rc≠0 |
| 5 | wait-ready: модель не загрузилась за `--ready-timeout` |
| 6 | verify: ответ ≠ 200 |

Потоки:

- **restart**: 1) preflight: юнит active/activating (иначе rc=2 —
  конвенция «осознанный стоп», F10), контейнер Up, парсинг ключа (в
  переменную; в логи/argv не попадает — R6), вердикт SAME_HOST →
  status-строка; 2) wait-idle: поллинг `/slots?model=$MODEL` (Bearer) 1 с,
  idle = в ответе ноль вхождений `"is_processing":true` (F7); таймаут →
  rc=3; 3) `$SYSTEMDCTL restart $UNIT` → rc=4 при неудаче; 4) wait-ready:
  `/health` ok **и** `/v1/models` `status.value="loaded"` (оба без ключа),
  1 с, таймаут → rc=5; 5) verify: `POST /v1/chat/completions`
  (`model=$MODEL`, `max_tokens=8`, Bearer) → 200, тайминги в status →
  rc=6 при неудаче; 6) done.
- **stop**: preflight → wait-idle → `$SYSTEMDCTL stop` (watcher сам
  skipнёт неактивный юнит, F10).
- **start**: preflight (юнит не active, контейнера нет) →
  `$SYSTEMDCTL start` → wait-ready → verify.
- **check**: read-only — preflight + SAME_HOST + состояние слотов
  (`is_processing`, `id_task`) + status модели из `/v1/models`; rc 0 —
  сервер доступен, 2 — нет. Изменений не вносит.

Status-файл (протокол опроса координатором): строки
`<ts> <state> <detail>`; states: `start` (с `pid`), `preflight`,
`same-host=yes|no|unknown`, `wait-idle`, `restarting`, `wait-ready`,
`verifying`, финальная `done rc=0` / `failed rc=<N> <reason>`.

Ключ: читается из файла в рантайме, используется только в
`Authorization: Bearer` заголовке; ни в логах, ни в status, ни в argv
(R6, no-sensitive). Запрет `curl -v` на keyed-эндпоинтах.

### 3. `Makefile`

- Переменные (рядом с `LLAMA_HOST`/`LLAMA_PORT`/`LLAMA_URL`):
  `LLAMA_MODEL ?= default`,
  `LLAMA_KEYS_FILE ?= /etc/llama/llama-cpp-keys.txt` (F11: конвенции уже
  существуют в sysconfig lact-autoswitch — сюда поднимаются как
  Makefile-переменные; override в `local.mk` возможен как для любых
  переменных).
- Таргет `llama-cpp-restart` (параметры `MODE` =
  restart|stop|start|check, дефолт `restart`; `IDLE_TIMEOUT=30`,
  `READY_TIMEOUT=600`, `VERIFY_REQUEST=`):
  - без `local.mk` — fail-loud (как `systemd`);
  - рецепт: `setsid -f env CRE=$(CRE) HOST_ROOT=$(HOST_ROOT)
    SYSTEMDCTL=$(SYSTEMDCTL) LLAMA_URL=$(LLAMA_URL)
    LLAMA_MODEL=$(LLAMA_MODEL) LLAMA_KEYS_FILE=$(LLAMA_KEYS_FILE)
    LLAMA_CONTAINER=$(LLAMA_CPP) ./scripts/llama-cpp-restart.sh $(MODE)
    --idle-timeout $(IDLE_TIMEOUT) --ready-timeout $(READY_TIMEOUT)
    < /dev/null >> $(RESTART_LOG) 2>&1`, затем echo путей
    `RESTART_LOG`/STATUS. `setsid -f` (always fork, F12) — рецепт
    возвращается сразу; скрипт живёт в своей сессии.
  - `RESTART_LOG ?= /tmp/llm-rig/llama-cpp-restart.log`.
  - sysconfig-gen `lact-autoswitch` (существующий вызов в `systemd`):
    зашитые литералы `--default LLAMA_MODEL=default` /
    `--default LLAMA_KEYS_FILE=/etc/llama/llama-cpp-keys.txt` →
    `$(LLAMA_MODEL)` / `$(LLAMA_KEYS_FILE)` (единственный источник
    значений).
  - Скрипт исполняется в шелле toolbx (рецепты make не исполняются на
    хосте даже при CRE=podman-remote); хост достигается через CRE/chroot —
    как в `systemd`-таргете.

### 4. `local.mk` — без новых переменных (анализ)

Машинно-зависимые значения, нужные скрипту, и их статус:

| Значение | Где | Комментарий |
|---|---|---|
| `LLAMA_HOST`, `LLAMA_PORT` | уже в `local.mk`/Makefile | без изменений |
| имя модели (`default`) | `LLAMA_MODEL ?= default` (Makefile) | конвенция F11; если на машине иная — override в `local.mk` существующим механизмом |
| путь к ключам | `LLAMA_KEYS_FILE ?= /etc/llama/llama-cpp-keys.txt` (Makefile) | проектная конвенция (маунт `/etc/llama` зашит в юнит, F9), не машинно-зависимо |
| имена контейнера/юнита | `LLAMA_CPP` (Makefile) | уже есть |

Итог: `local.mk` и `local.mk.example` **не меняются** (решение
пользователя 02.09.2026: не раздувать local.mk). Новые секретных значений
нет → `test-no-sensitive` без изменений.

### 5. `LIVE-SERVER.md` (корень репо, tracked, без секретов)

~70 строк, секции:

1. Когда читать: деятельностный триггер — рестарт/стоп/старт, ключи,
   sysconfig, контейнер/юнит, прод-логи (правило — `AGENTS.md`, §6).
2. Топология и факты: роутер :8080 → инстансы (порты не опубликованы, F4);
   CRE/chroot/toolbx net=host (F2/F3); эндпоинты и какие ключевые
   (F5–F7); ключи: путь, парсинг, не писать в лог (F8).
3. SAME_HOST: правило (§1) и что оно значит для сессии.
4. Рестарт/стоп/старт: `make llama-cpp-restart MODE=...`; self-healing
   (setsid); протокол status-файла (states, таблица rc); как координатор
   опрашивает.
5. Взаимодействие с юнитом/watcher: конвенция «осознанный стоп»,
   `Restart=always`/30 s, zombie-сигнатуры (указатель на
   `scripts/llama-cpp-watcher.sh`); смена образа: sysconfig `LLAMA_IMAGE`
   (`make systemd` → рестарт).
6. Числа: даунтайм (t0→t1), загрузка модели (t1→t2), verify (t3),
   ре-префилл первого запроса после рестарта (cache-ram пуст) — заполнить
   после live-окна (пока: указатель на отчёт).
7. Логи: указатель на секцию AGENTS.md «Логи llama-server (llama-cpp)» +
   `podman-remote logs llama-cpp` накапливается между рестартами.

### 6. `AGENTS.md`

Секция «Живой сервер (llama-cpp)» — 2–3 строки:

> Живой сервер llama-cpp: перед первым действием над ним (рестарт/стоп/
> старт, ключи, sysconfig, контейнер/юнит, прод-логи) — прочитать
> `LIVE-SERVER.md`.

Контекст не засоряется: файл подтягивается только по делу; систематический
дебаг живого сервера покрывается тем же триггером (дебаг = работа с
прод-логами/контейнером).

### 7. Тесты

- `scripts/test-llama-cpp-restart.sh` (новый; ok/ko-конвенция репо):
  - `bash -n` скрипта;
  - hermetic-прогон на mock-сервере (python3 `http.server`: `/health`,
    `/v1/models`, `/slots` с управляемым `is_processing`,
    `/v1/chat/completions` (200, для verify)) + PATH-stubs
    `podman` (ps/inspect) и `systemctl` (запись вызовов, rc 0); env:
    `CRE=podman`, `SYSTEMDCTL=systemctl`, `STATUS`/лог в tmp:
    - `check` против mock: rc 0, статус SAME_HOST по mock-конфигу
      opencode (временный `$HOME`);
    - wait-idle: mock с `is_processing=true` + `--idle-timeout 2` → rc=3,
      вызова systemctl restart **нет**; переключение mock в idle → rc=0,
      restart вызван ровно один раз, затем verify 200;
    - ключ из mock-файла (комментарии/пустые строки) не встречается в
      логе/STATUS;
    - flock: второй запуск при занятой блокировке abort.
- `scripts/test-makefile-graph.sh`: `llama-cpp-restart` в цикл `make -n`
  (MODE=check): в рецепте `setsid -f`, `scripts/llama-cpp-restart.sh`,
  plumbing `CRE`/`SYSTEMDCTL`/`LLAMA_URL`/`LLAMA_MODEL`; local.mk-стуб —
  как в существующем тесте; без local.mk — fail-loud (rc=2, как systemd).
- Полный тест-сьют зелёный (13 → 14 скриптов).
- Живые сценарии (in-flight abort, полный рестарт) — только в live-окне
  (§9): hermetic-тест покрывает логику, живое окно — реальный сервер.

## Риски и митигации

| # | Риск | Митигация |
|---|---|---|
| R1 | Семантика `/health` роутера при загрузке модели неизвестна (F5) | Ready-gate — `/v1/models` loaded + verify, `/health` не единственный; live-окно замеряет и фиксирует в LIVE-SERVER.md §6 |
| R2 | Долгая генерация дольше `--idle-timeout` (30 c) | rc=3 abort без форса (stop/restart-hang при in-flight, архив); повтор после завершения хода либо явное увеличение `IDLE_TIMEOUT` оператором |
| R3 | Сессия умирает в процессе рестарта | По дизайну: `setsid -f` + status-файл — скрипт доводит сервер до готовности без сессии (self-healing); координатор возвращается и опрашивает status |
| R4 | Opencode-конфиг в другом месте/формате | Правило использует только grep `"baseURL"` + host/порт; нет конфига → SAME_HOST=unknown → консервативно (wait-idle + setsid), заметка в status |
| R5 | `/tmp/llm-rig` — per-boot, при reboot путь пуст | Не критично: операции короткоживущие; скрипт `mkdir -p` при старте |
| R6 | Утечка ключа (лог, argv, /proc) | Ключ — только из файла в рантайме, в `Authorization`-заголовке; без `curl -v` на keyed-эндпоинтах; hermetic-тест проверяет отсутствие ключа в логе/STATUS |

## Live-окно (после SDD-реализации)

1. Pre: снимки (`podman-remote inspect llama-cpp`,
   `/etc/sysconfig/llama-cpp`, args из `/v1/models`, состояния
   юнита/watcher), git-состояние ветки `stage25-safe-restart`.
2. Прогон 1: `make llama-cpp-restart MODE=check` → SAME_HOST=yes, слоты
   idle, модель loaded.
3. Прогон 2 (in-flight abort): фоновая долгая генерация (`setsid` curl
   stream, `model=default`, `max_tokens≈500`) + `MODE=restart
   IDLE_TIMEOUT=5` → ожидаем rc=3 (status: wait-idle → failed), сервер
   **не** рестартован (Up-time не изменился), генерация завершилась.
4. Прогон 3 (полный рестарт, замеры): долгая генерация + `MODE=restart
   IDLE_TIMEOUT=120` → скрипт ждёт завершения генерации, затем рестарт:
   t0 (старт) → t1 (первый `/health` ok) → t2 (`/v1/models` loaded) →
   t3 (verify 200, tok/s). Приёмка: rc=0, verify 200, **сессия
   координатора продолжает работу после рестарта** (написание отчёта —
   сама по себе приёмка), замечен ре-префилл первого запроса.
5. Статика: `scripts/test-llama-cpp-restart.sh` + полный тест-сьют —
   зелёные.
6. Post: отчёт `docs/superpowers/reports/2026-09-0X-stage25-safe-restart.md`
   (таймлайн, числа → LIVE-SERVER.md §6, семантика `/health` → R1),
   чекбоксы `TODO.md`, finishing-a-development-branch (merge в `main`).

## Критерии готовности

- файлы: `scripts/llama-cpp-restart.sh`,
  `scripts/test-llama-cpp-restart.sh`, `LIVE-SERVER.md`, `Makefile`
  (2 переменные + таргет `llama-cpp-restart`; sysconfig-gen
  lact-autoswitch на `$(LLAMA_MODEL)`/`$(LLAMA_KEYS_FILE)`),
  `AGENTS.md` (секция), `scripts/test-makefile-graph.sh` (pin);
  `local.mk`/`local.mk.example` без изменений;
- тест-сьют зелёный (включая новый hermetic-тест);
- live-окно: прогоны 1–3 по протоколу, сессия пережила рестарт, числа в
  `LIVE-SERVER.md` §6;
- `TODO.md` Этап 25: чекбоксы отмечены;
- finishing: merge `stage25-safe-restart` → `main`.
