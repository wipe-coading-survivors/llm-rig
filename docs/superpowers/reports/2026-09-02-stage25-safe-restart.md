# Этап 25 — live-окно: безопасный рестарт живого llama-cpp-сервера

Дата: 2026-09-02. Ветка: `stage25-safe-restart` (01358ef). Протокол: спека,
секция «Live-окно»; операции — `LIVE-SERVER.md`.

## 1. Pre-снимки (17:15 MSK / 14:15 UTC)

- Часы: toolbx 17:15:16 MSK = 14:15:16 UTC (MSK = UTC+3, подтверждено).
- Контейнер `llama-cpp`: status=running,
  started=**2026-09-02 09:01:29.284 +0300**, created=09:01:29.134,
  image=`localhost/llama-cpp-cuda:13.3`.
- `/etc/sysconfig/llama-cpp`: `LLAMA_IMAGE=llama-cpp-cuda:13.3`,
  `LLAMA_LOG_TIMESTAMPS=1`, `LLAMA_PORT=8080`, `LLAMA_SHM_SIZE=64g`.
- `/v1/models` (без ключа): id=`default`, `status.value=loaded`; args
  инстанса (доказательство тождества): `llama-server --api-key-file
  /root/llama/llama-cpp-keys.txt --port 35119 --alias default --ctx-size
  430000 --cache-ram 65536 --cache-type-k q8_0 --cache-type-v q8_0
  --swa-checkpoints 64 --flash-attn on --no-kv-unified --load-mode mlock
  --model /models/qwen3.8-27b-ud-q8_k_xl.gguf --n-predict 24000
  --n-gpu-layers all --parallel 2 --split-mode tensor --threads 28
  --tensor-split 1,1,1,1,1 --spec-type draft-mtp --spec-draft-n-max 2 ...`
  (полный список в /v1/models; сверка: порт 35119, alias default —
  тот же сервер, что обслуживает сессию).
- Юниты: `llama-cpp` active, `llama-cpp-watcher` active.
- git: дерево чистое, HEAD=01358ef, ветка `stage25-safe-restart`.
- Слоты до окна (ключ через 0600 `-K`-конфиг):
  - slot 0: `is_processing=false`, `n_prompt_tokens=58887`, n_ctx=215040;
  - slot 1: `is_processing=true`, `n_prompt_tokens=177582`, n_ctx=215040
    (сессия координатора; длина контекста для замера ре-префилла).

## 2. Прогон 1: `MODE=check` (read-only) — 17:16:43

Принято: `SAME_HOST=yes`, слоты idle, модель loaded, `rc=0`.

```
2026-09-02T17:16:43 start pid=1440493 mode=check url=http://10.88.0.1:8080 model=default
2026-09-02T17:16:43 preflight ok unit=active
2026-09-02T17:16:43 same-host yes
2026-09-02T17:16:43 check slots busy=0
2026-09-02T17:16:43 check model loaded
2026-09-02T17:16:43 done rc=0
```

Замечания:
- Рецепт расширился с кавычками: `SYSTEMDCTL="chroot /run/host
  /usr/bin/systemctl"` — как один аргумент env (C1-фикс работает в проде).
- `LLAMA_URL=http://10.88.0.1:8080` — `LLAMA_HOST` из operator-`local.mk`
  (host-IP из toolbx-нетнс); SAME_HOST-вердикт при этом `yes` (baseURL
  сессии 127.0.0.1:8080 совпадает по порту — оба адреса доходят до сервера).
- `slots busy=0` — во время tool-вызова генерация сессии паузится, слот
  координатора idle (busy-флаг живёт только во время генерации токенов).

## 3. Прогон 2: in-flight abort (`IDLE_TIMEOUT=5`, ожидаем rc=3) — 17:19:02

Фоновая генерация (setsid curl, model=default, `max_tokens=1000`,
prompt 75 токенов) + `make llama-cpp-restart MODE=restart IDLE_TIMEOUT=5`.
Отклонение от спеки: `max_tokens=1000` вместо «≈500» — запас на случай
высокого tok/s (500 токенов при 100 tok/s = ровно 5 s, граница таймаута).

Принято: rc=3, сервер **не** рестартован, генерация завершилась.

```
2026-09-02T17:19:02 start pid=1441652 mode=restart url=http://10.88.0.1:8080 model=default
2026-09-02T17:19:02 preflight ok unit=active
2026-09-02T17:19:02 same-host yes
2026-09-02T17:19:02 wait-idle timeout=5s model=default
2026-09-02T17:19:12 failed rc=3 in-flight: слоты заняты 5s (abort без форса)
```

- `podman-remote inspect`: started=**09:01:29.284** — не изменился.
- Генерация: завершилась после abort (файл 0 байт на 15-й секунде —
  curl без `-N` буферизует; полный ответ к моменту чтения):
  `usage: completion_tokens=1000, prompt_tokens=75, total_tokens=1075`.
- Забег в ~18 s (1000 токенов) покрыл 5-s окно wait-idle с запасом;
  слот был занят фоном, а не сессией координатора (тот был idle).

## 4. Прогон 3: полный рестарт, замеры t0→t3

Хореография: фоновая генерация 1000 токенов (setsid curl, старт 17:22:44)
+ `make llama-cpp-restart MODE=restart IDLE_TIMEOUT=120`. wait-idle
дождался завершения генерации (17:24:01), затем — рестарт.

```
2026-09-02T17:22:44 start pid=1443466 mode=restart url=http://10.88.0.1:8080 model=default
2026-09-02T17:22:44 preflight ok unit=active
2026-09-02T17:22:44 same-host yes
2026-09-02T17:22:44 wait-idle timeout=120s model=default
2026-09-02T17:24:01 wait-idle idle
2026-09-02T17:24:01 restarting via unit llama-cpp
2026-09-02T17:25:47 wait-ready timeout=600s model=default
2026-09-02T17:26:39 wait-ready model loaded
2026-09-02T17:26:39 verifying model=default
2026-09-02T17:26:41 verifying 200 OK
2026-09-02T17:26:41 done rc=0
```

Таймлайн (MSK, `journalctl -lu llama-cpp`):

| t | время | событие |
|---|-------|---------|
| t0 | 17:24:01 | `systemctl restart` (SIGTERM podman) |
| — | 17:25:31 | `stop-sigterm timed out` (90 s) → SIGABRT podman/conmon |
| — | 17:25:32 | юнит Stopped; старт №1 |
| — | 17:25:47 | старт №1: `podman run` exit **125** (труп старого контейнера держал имя/порт) |
| — | 17:26:17 | `Restart=always` + `RestartSec=30`: старт №2; `ExecStartPre podman rm -f` убрал труп; новый контейнер 81a647b |
| t1 | 17:26:18 | роутер `listening on http://0.0.0.0:8080` (первый /health ok) |
| t2 | 17:26:39 | instance `model loaded` (порт 37397 — эфемерный, был 35119) |
| t3 | 17:26:41 | verify 200 OK (генерация 8 токенов) |

Числа (каждое — с длиной контекста на момент измерения):

- **t0→t1 даунтайм = 137 s** (запросов нет; контекст не применим).
- **t1→t2 загрузка модели = 21 s** (27B q8, mlock, 4×GPU tensor split,
  page cache тёплый; запросов ещё нет).
- **t3 verify**: prompt **58 токенов** — prefill 1037.6 ms (55.90 t/s),
  генерация 8 токенов 404.6 ms (17.30 t/s, холодные CUDA graphs:
  `graphs reused = 2`); total 1442 ms.
- **Ре-префилл сессии** (task 9, первый запрос после рестарта, cache-ram
  пуст): **117645 prompt-токенов → 181.2 s (649.23 t/s, 1.54 ms/токен)**;
  полный запрос (+генерация 6159 токенов @ 45.29 t/s) — 317.2 s
  (17:26:45 → 17:32:02).

Семантика `/health` (R1): уровень **роутера** — /health ok (t1) наступает
**до** загрузки модели (t2): процесс роутера up, instance грузит. Пока
контейнер мёртв (17:24:01–17:26:18) — /health: connection refused.
Поэтому ready-gate — `/health` ok **и** `/v1/models` `loaded` (оба
сигнала), как и реализовано в скрипте.

Наблюдения live:

1. **Known-issue stop/restart-hang воспроизведён**: stop-sigterm
   таймаут 90 s → SIGABRT. На момент SIGTERM слоты были idle (wait-idle
   прошёл), но последний task (фоновая генерация, task 216417 старого
   instance) освободился в ту же секунду (17:24:01.245) — гонка при
   shutdown. Дизайн скрипта поглотил инцидент: wait-ready (бюджет 600 s)
   перекрыл stop+start целиком, вмешательств не потребовалось.
2. **Старт №1 упал (exit 125)**: SIGABRT убил podman-клиент, но старый
   контейнер выжил на стороне движка (труп); новый `podman run` не смог
   стартовать (имя/порт заняты). `Restart=always` + `RestartSec=30` →
   старт №2, где `ExecStartPre podman rm -f` убрал труп → успех. Скрипт
   о падении не «знал» (он видит юнит и эндпоинты) — ready-gate ждал.
3. Старый instance проработал 8 h 24 min (task № до 216417); новый —
   нумерация task с 1 (совпадает с `AGENTS.md`, секция «Логи»).
4. Watcher: за окно записей нет (не вмешивался).
5. Сессия координатора **пережила рестарт**: первый пост-рестартный
   запрос (task 9) сделал полный ре-префилл контекста (117645 токенов)
   без потерь; отчёт пишется этой же сессией (принимка).
6. Компакции opencode в окне: контекст сессии 177582 (17:15) → 117645
   (task 9, 17:26:45) → 43205 (task 2404, 17:32:03) токенов —
   client-side компакция, не серверная.
7. Скачок task-номеров 9 → 2404 (в пределах нового instance) — счётчик,
   вероятно, включает внутренние запросы роутера; на поведение не
   влияет.
8. Тождество: image не изменился (`llama-cpp-cuda:13.3`), ключевые args
   инстанса совпадают с pre-снимком (`--model /models/qwen3.8-27b-ud-
   q8_k_xl.gguf --ctx-size 430000 --cache-ram 65536 --parallel 2
   --tensor-split 1,1,1,1,1 --spec-type draft-mtp --load-mode mlock`);
   `--port` — эфемерный (35119 → 37397). Полный args post-restart:
   `/app/llama-server --api-key-file /root/llama/llama-cpp-keys.txt
   --host 127.0.0.1 --jinja --metrics --min-p 0.05 --numa distribute
   --port 37397 --presence-penalty 0.0 --reasoning-budget-message 16384
   --reasoning-preserve --repeat-penalty 1.0 --spec-draft-n-max 2
   --spec-type draft-mtp --temperature 1.0 --top-k 20 --top-p 0.95
   --alias default --ctx-size 430000 --checkpoint-min-step 128
   --cache-ram 65536 --cache-type-k q8_0 --cache-type-v q8_0
   --swa-checkpoints 64 --flash-attn on --no-kv-unified --load-mode
   mlock --model /models/qwen3.8-27b-ud-q8_k_xl.gguf --n-predict 24000
   --n-gpu-layers all --parallel 2 --split-mode tensor --threads 28
   --tensor-split 1,1,1,1,1`

## 5. Статика

Полный тестовый сет после live-окна — **14/14 green, 831 assertion**:
test-debug-scripts 28, test-kmod-select 29, test-lact-apply-retry 15,
test-lact-pci-bdf 4, test-lact-render 118, test-llama-cpp-restart 29,
test-llama-cpp-watcher 23, test-lact-autoswitch.py 53,
test-makefile-graph 346, test-makefile-redist 21, test-no-sensitive 3,
test-redist-check 11, test-safe-rm 28, test-sysconfig-gen 11,
test-systemd-units 112. (Запуск: `sh scripts/test-*.sh` +
`python3 scripts/test-lact-autoswitch.py`; часть скриптов в репо без
`+x` — предсуществующая конвенция.)

## 6. Итог / приёмка

- [x] `MODE=check`: SAME_HOST=yes, слоты idle, model loaded, rc=0.
- [x] In-flight abort: rc=3 (wait-idle timeout 5 s), сервер **не**
      рестартован (контейнер StartedAt не изменился), генерация
      завершилась.
- [x] Полный рестарт: rc=0 — несмотря на два промежуточных сбоя юнита
      (stop-hang 90 s + старт №1 exit 125); t0→t1 137 s, t1→t2 21 s,
      t3 verify 200 OK.
- [x] Приёмка: сессия координатора пережила рестарт — первый
      пост-рестартный запрос сделал ре-префилл полного контекста
      (117645 токенов, 181 s @ 649 t/s); отчёт написан этой же сессией.
- [x] Числа записаны в `LIVE-SERVER.md`, секция «Числа».
- [x] Статика green (14/14).

Вывод: Этап 25 принят. Дизайн скрипта (wait-idle без форса, self-healing
через `setsid -f`, ready-gate по двум сигналам, бюджет 600 s) выдержал
живой рестарт с hang'ом на стопе и упавшим стартом №1 — без
вмешательства оператора.
