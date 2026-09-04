# Отчёт — Этап 27: lact-autoswitch, pin `safe` при crash/thermal-loop

Дата live-окна: 04.09.2026, ~00:30–00:39 MSK (часы контейнера — UTC,
строки хелпера в журнале — `2026-09-03T21:3x` = те же моменты).
Ветка `stage27-pin-safe`, базовая точка `before-stage-027` → `b19a9ae`.
Спека: `docs/superpowers/specs/2026-09-03-stage27-pin-safe-design.md`;
план: `docs/superpowers/plans/2026-09-03-stage27-pin-safe.md`.

## Что сделано

1. **Watcher → хелпер (канал событий)**: `llama-cpp-watcher.sh` при
   каждом детекте краха (после cooldown-гейта и guard, в точке
   ERR-строки) дописывает целую epoch-секунду в
   `/run/lact-autoswitch/crashes` (trim до 100 строк, tmp+mv,
   env-override `CRASH_EVENTS_FILE` для тестов).
2. **Хелпер (политика pin)**: env-настройки (`CRASH_PIN_COUNT=3`,
   `CRASH_PIN_WINDOW=600`, `THERMAL_PIN_COUNT=3`,
   `THERMAL_PIN_WINDOW=1800`, `PIN_LOG_EVERY=300`,
   `PIN_FILE=/run/lact-autoswitch/pin`,
   `CRASH_EVENTS_FILE=/run/lact-autoswitch/crashes`), чистые функции
   (`decide_pin`, `read_crash_events`, `parse_pin_file`,
   `pin_log_due`, `write_pin_file`) + pin-состояние в main-loop:
   триггер (3 краша в 600 c или 3 терм-демота в 1800 c) →
   pin-файл + `apply_profile("safe")`; во время pin — потолок
   (блокируется только переход на `Default`/OC, `idle`/`safe`
   проходят); release — оператор `rm` файла; adoption при старте и
   при появлении файла mid-run; pin переживает рестарты хелпера
   (tmpfs → reboot чистит).
3. **Деплой**: unit `lact-autoswitch.service` +5 `-e` (5 ключей;
   `PIN_FILE`/`CRASH_EVENTS_FILE` — код-дефолты, не передаются),
   sysconfig-gen +5 `--default`, пины тестов (unit/graph).
4. **Тесты**: watcher 32 (TAP sh), хелпер 70 (TAP py, 17 новых),
   systemd-units 124, makefile-graph 357 — полный сьют зелёный.
5. **Live-окно**: E2E file-инъекцией (без индукции реальных
   крашей/перегрева — спека §6).

## Пре-снапшот (00:30 MSK)

- `is-active lact-autoswitch llama-cpp-watcher llama-cpp` = active×3.
- `/run/lact-autoswitch/` — только `history.log` (71 299 B); файлов
  `pin`/`crashes` нет.
- Журнал хелпера за 10 мин — пуст (профилей не переключалось).
- `/etc/sysconfig/lact-autoswitch` — 16 строк, pin-ключей нет.
- `LLAMA_MEM=160g` в `/etc/sysconfig/llama-cpp` (зона оператора,
  не трогалась).

## Деплой (00:30–00:31)

- `make nvidia-lact-autoswitch`: образ
  `nvidia-lact-autoswitch-610.43.03:v0.10.0` (`8b33319c18c0`),
  STEP 4/4 — только COPY-слой хелпера (без dnf).
- `make systemd`: sysconfig +5 pin-дефолтов (существующие значения
  не тронуты, `LLAMA_MEM=160g` сохранён), unit +5 `-e`,
  `LACT_AUTOSWITCH_IMAGE=...:v0.10.0`, watcher-скрипт на хост
  (с `record_crash_event`), keys 640, `daemon-reload` + `enable`.
- `systemctl restart lact-autoswitch llama-cpp-watcher` (00:31:21):
  оба active; хелпер: `start: key found (marker 'lact-autoswitch'),
  poll=5s thermal-every=3`; `pin:`-строк нет (pin-файла нет).

## E2E (фактические строки журнала)

Сессия была активной (load=busy) — блок-логи видны.

**E2E-1 — ручной pin (touch) + release (rm), 00:31:47/00:32:12:**

```
pin: ACTIVE (external) - safe held
pin: transition to Default blocked (active) - fix the root cause: OC under an unresolved issue degrades the GPU
pin: released - actual=Default adopted, switching resumed
```

(без age в released — external touch, ts неизвестен; блок-лог —
reason `active`.)

**E2E-2 — crash-триггер (3 фейковых ts), 00:34:14/00:34:40:**

```
pin: ACTIVE reason=crashes count=3 window=600 n=1 - safe held; release: rm /run/lact-autoswitch/pin
```

`nvidia-smi --query-gpu=power.limit` после триггера:
**120.00 W × 5** (safe-профиль, OC деградирован). После `rm`
pin+crashes:

```
pin: released (age=0m) - actual=safe adopted, switching resumed
switch: safe -> Default (active)
```

`power.limit` после release: **140.00 W × 5** (OC восстановлен).
Окно деградации OC — ~26 c (триггер→release).

**E2E-3 — персистентность через рестарт хелпера, 00:37:16/00:37:51:**

pin-файл с парсебельной строкой → `systemctl restart
lact-autoswitch` → новый инстанс:

```
pin: ACTIVE (adopted at start) age=1m - safe held
pin: transition to Default blocked (active) - fix the root cause: OC under an unresolved issue degrades the GPU
```

— pin пережил рестарт (ключевое свойство); до рестарта старый
инстанс поймал тот же файл как external (блок-лог 00:36:47) — оба
пути adoption подтверждены. После `rm`:

```
pin: released (age=2m) - actual=Default adopted, switching resumed
```

## Финал (00:38)

- `is-active` ×3 = active.
- `/run/lact-autoswitch/` — только `history.log`; `pin`/`crashes`
  удалены.
- Обычный трафик хелпера, алармов нет.
- `llama-cpp`: `uid=1001001 gid=0` (non-root не сломан);
  `LLAMA_MEM=160g` на месте.

## Девиации

- **Stage-tag ретроспективно** (ruling R3): `before-stage-027` →
  `b19a9ae` (HEAD до этапа); spec/plan/TODO-коммиты этапа попали в
  main до старта SDD (установившийся в этой сессии порядок:
  доки → main, исполнение → ветка).
- **`make nvidia-lact-autoswitch` вместо `make llama-cpp-cuda`** из
  спеки §6: хелпер живёт только в lact-autoswitch-образе
  (llama-cpp-образ не содержит его) — пересборка всей CUDA-цепи
  не нужна; COPY-слой дешевле.
- **Plan-fix-коммиты** (rulings R1, R4–R6): счётчик TAP-чеков
  (17/70, не 19/72); `reset_kill_log` в тесте 4.9; AttributeError-
  guard вокруг блока 17 чеков (внешний `try:` файла без `except`);
  два непроходимых grep-пина (`grep -m1` без `-o`; mid-pattern
  `${VAR}` в ERE). Все — до dispatch/по факту RED, верифицированы.

## Rulings (из ledger)

- R1: план-счётчик тестов 72 → 70 (17 новых TAP-чеков).
- R2: без worktree (live-окно требует toolbx-среды; ветка + PR).
- R3: stage-tag ретроспективно на `b19a9ae`.
- R4: `reset_kill_log` в тесте 4.9 — вербальтим-блок плана
  непроходим (kill-лог копится между тестами).
- R5: AttributeError-guard вокруг блока 17 чеков — конвенция файла,
  без него RED погибает traceback'ом до TAP-сводки.
- R6: два grep-пина плана непроходимы (см. девиации).
- R7 (final review): ceiling-фикс — при `fallback_on` подавляемый
  target := `safe` (не `HOLD`), иначе socket-up HOLD релизил бы
  fallback в stock 170/180 W (см. «Final review + fix wave»).

## Наблюдения (не дефекты)

- **Ручной pin не деградирует уже OC-карту**: forced safe — только
  на триггер-пути (`actual != safe → apply_profile("safe")`);
  external/adopted pin при `actual=Default` держит профиль как есть
  и блокирует только переходы *на* Default (HOLD = «не менять»).
  Семантика спеки §4.2 (утверждена); ценность ручного pin —
  персистентность потолка через рестарты/деплой. Строка лога
  «safe held» — wording спеки для adoption, не утверждение о
  текущем профиле.
- `last_block_log` не сбрасывается при release (deferred minor,
  Task 3): первый блок-лог нового эпизода после release может
  задержаться до `PIN_LOG_EVERY` (300 c).
- exists→parse race при `rm` pin-файла: один лишний pinned-цикл,
  self-heal через release (deferred minor, Task 3).
- Pre-existing (не из этапа): 2 строки `grep: warning: stray \
  before -` в stderr `test-systemd-units.sh`.
- Кандидат в TODO: fan-fail (температура растёт и под safe PL 120)
  — см. TODO «Кандидаты на этапы».

## Final whole-branch review + fix wave

Ревью (весь диапазон ветки) вернуло один Important —
кросс-задачный разрыв, невидимый для per-task ревью:
pin-blocked `HOLD` при **socket up** + активном `fallback_on`
(эпизод socket-down/overtemp) запускал существующую 16.2-ветку
`release_fallback()` — stock-дефолты **4x170 + LHR 180 W** (выше OC
140 W и выше safe-потолка 120 W), при этом state-машина хелпера
этого не видит. До ветки `HOLD` был достижим только при socket down
(`decide_target`), новая ceiling сделала socket-up HOLD реальным.

**Ruling R7 — фикс** (`eaf5df7`): в ceiling-блоке при `fallback_on`
подавляемый target роутится в `safe` (не `HOLD`) — socket up, демон
на связи, существующий механизм apply заменяет raw-фолбэк полным
safe-профилем (PL 120 + fan + offsets), `fallback_on` чистится.
Спека §4.2 дополнена одной строкой. В тот же wave (re-review:
все findings ADDRESSED, new breakage — None):
`4783501` — functional-тест mkdir -p несуществующего каталога
(спека §6, был только structural pin); `d6bac84` — runbook: снятие
пина = `rm` pin-файла (+ `rm` crashes-файла, если цикл крахов
закончен, иначе re-pin в окне 600 c).

## Fresh-deploy после fix wave (01:26 MSK)

Хелпер изменился после live-окна → пересборка + деплой
(COORDINATOR-правило): `make nvidia-lact-autoswitch`
(образ `...:v0.10.0`, `c88a29368e3e`, COPY-слой) + `make systemd` +
`systemctl restart lact-autoswitch` — active, `start: key found`,
`pin:`-строк нет, power.limit = 140.00 W (OC), `pin`/`crashes`
файлов нет.

## Коммиты (ветка `stage27-pin-safe`)

`b40e2ba` watcher-события · `d248caf` plan fix R4 · `8755fed`
чистые pin-функции + TAP + README-сьют · `29d7732` plan fix R5 ·
`d5a7497` аддендум спеки · `ca446f7` pin-состояние main-loop ·
`456bd13` деплой (unit/sysconfig/пины) · `795407c` plan fix R6 ·
`c09a0b1` README runbook-строка · `3ea9fe1` TODO + close-отчёт ·
`eaf5df7` fix: ceiling→safe при fallback (R7) · `4783501`
mkdir-тест · `d6bac84` runbook rm-crashes.
