# Мемо: llama-cpp auth — `--api-key-file` перенесён в роутер (образ a01ce9ffc)

- Дата: 24.10.2026
- Тип: live-фикс, вне плана/спеки (реакция на открытую авторизацию).

## Что случилось

- 20.10 (12:26 UTC) образ `localhost/llama-cpp-cuda:13.3` пересобран из
  llama.cpp master (sha `a01ce9ffc64cf370439d6f861a534a65100133ae`) как
  побочный эффект цепочки «ядро → драйверы»; контейнер перезапустился
  21.10 ~11:33 MSK.
- После этого сервер отвечал **без авторизации**: keyless
  `/v1/models`, `/slots`, `POST /v1/chat/completions` → 200.
- Корневая причина: в новом llama.cpp строка `api-key-file` в
  `[*]`-секции пресета `llama.ini` **игнорируется** (старый образ
  применял её — ключ стоял в args инстанса; новый — нигде). В логе
  роутера: `security: no API key is set and CORS allows all origins`.
- Сессия opencode была под риском; ключ в
  `~/.local/share/opencode/auth.json` совпадает со строкой файла
  `/etc/llama/llama-cpp-keys.txt` (сверено без печати ключа) — после
  фикса сессия продолжает работать.

## Решение

- Ключ отдаётся **роутеру** `--api-key-file /llama/llama-cpp-keys.txt`
  в аргументах юнита. Инстансу ключ не нужен: он на `127.0.0.1`
  внутри контейнера и наружу не опубликован, единственный вход —
  роутер. Файл контейнер читает (gid 0, non-root).

## Изменения

- Репо (не закоммичено на 24.10):
  - `resources/llama/llama-cpp.service`: аргументы роутера `--api-key-file
    /llama/llama-cpp-keys.txt --metrics`;
  - `debug/llama-run.sh`: тот же флаг (зеркало юнита);
  - `scripts/llama-cpp-restart.sh`: `wait_ready` + `check_mode` —
    `/v1/models` опрашивается **с ключом** (`get /v1/models 0 → 1`);
    в новом образе `/v1/models` keyed, keyless-опрос → 401 → ложный
    `rc=5 «не готов»` при живом сервере;
  - пины: `scripts/test-systemd-units.sh`, `scripts/test-debug-scripts.sh`
    (api-key-file в юните/зеркале); `scripts/test-llama-cpp-restart.sh`
    (mock `/v1/models` keyed, как в реальном образе; readiness-проба
    мока — `/health` без `-f`; пин «/v1/models keyed в скрипте»).
- Host one-shot (вне репо):
  - `/etc/llama/llama.ini`: строка `api-key-file` заменена комментарием
    (бэкап `llama.ini-7`);
  - `make systemd`: юнит задеплоен.

## Верификация

- Тесты: `test-llama-cpp-restart` **30/30** (до фикса скрипта — RED:
  6 падений, в т.ч. `restart full rc=5`, как в live),
  `test-systemd-units` 125/0, `test-debug-scripts` 38/0.
- Live `MODE=restart` 24.10 14:34:55: сервер поднялся **с auth**
  (журнал: `unauthorized: Invalid API Key` на keyless-запросы), но сам
  скрипт вышел `failed rc=5 не готов 600s (health=200)` — ждал keyless
  `/v1/models` → 401; сервер при этом был готов. Те самые 401-строки
  с интервалом ~1 c в журнале — цикл `wait_ready` этого скрипта.
- После фикса `MODE=check` 14:54:50: `check slots busy=0`,
  `check model loaded`, **`done rc=0`**.
- Auth-батарея (live): без ключа — `/health` 200 (единственный
  публичный), `/v1/models` 401, `/slots` 401, POST chat 401; с ключом
  — `/v1/models` 200, `/slots?model=default` 200, POST chat 200
  (модель отвечает).
- Побочное открытие: в новом образе `GET /slots` требует
  `?model=<M>` (иначе 400 «model name is missing from the request»);
  скрипт уже использовал `?model=$LLAMA_MODEL` — изменений не потребовалось.

## Разъяснение «пинговалки»

- `llama-cpp-watcher.sh` (юнит `llama-cpp-watcher.service`) HTTP-пинов
  не делает — работает по журналу (zombie-сигнатуры `CUDA error: ...`,
  cooldown 120 s). На auth-схему не влияет; менять не нужно.
