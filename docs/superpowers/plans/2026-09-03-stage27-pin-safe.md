# Stage 27 Implementation Plan — lact-autoswitch: pin `safe` при crash/thermal-loop

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** После N child-крахов (события watcher'а) или M термальных
демотов (хелпер) — pin GPU-профилей под потолком `safe` (блок переходов
на `Default`/OC до явного снятия оператором), с явными journal-логами.

**Architecture:** Watcher (host-скрипт) при каждом детекте краха
дописывает epoch-секунду в общий файл `/run/lact-autoswitch/crashes`;
вся pin-политика — в хелпере (Python в LACT-контейнере): читает
crash-файл, считает свои терм-демоты, пишет `/run/lact-autoswitch/pin`
(переживает рестарты хелпера; tmpfs → reboot чистит), во время pin'а
подавляет переходы на `Default` (потолок, не фиксация: `idle`/`safe`
проходят), логирует rate-limited «blocked»-строки. Снятие — оператор
`rm` pin-файла.

**Tech Stack:** bash (host-скрипт), Python 3 stdlib (контейнерный
хелпер), systemd unit + sysconfig-gen (деплой), TAP-тесты (sh + py),
hermetic PATH-shim harness (паттерн `test-llama-cpp-watcher.sh` /
`test-safe-rm.sh`).

**Spec:** `docs/superpowers/specs/2026-09-03-stage27-pin-safe-design.md`

## Global Constraints

- Env-дефолты (спека §4.2, дословно): `CRASH_PIN_COUNT=3`,
  `CRASH_PIN_WINDOW=600`, `THERMAL_PIN_COUNT=3`,
  `THERMAL_PIN_WINDOW=1800`, `PIN_LOG_EVERY=300`,
  `PIN_FILE=/run/lact-autoswitch/pin`,
  `CRASH_EVENTS_FILE=/run/lact-autoswitch/crashes`.
- Pin-семантика — **потолок**: блокируется только `Default`;
  `idle`/`safe`/`FALLBACK`/`HOLD` проходят по обычной логике (спека
  §2, §4.2).
- Pin-файл: presence = pin активен (в т.ч. пустой `touch`);
  парсибельная строка — `reason=<crashes|thermal> count=<k>
  window=<s> ts=<epoch> n=<int>`; переживает рестарт хелпера;
  auto-expiry нет.
- Строки логов — по спеке §4.4, англ., lowercase, префикс `pin:`.
  Два уточнения (аддендум к спеке, Task 3 Step 1): (а) в коде ASCII `-`
  вместо типографского `—` (стиль существующих логов хелпера);
  (б) блок-строка: `pin: transition to Default blocked (<reason>) - fix
  the root cause: OC under an unresolved issue degrades the GPU`, где
  `<reason>` — причина решения (`active`, `auth-streak`) —
  `(load=busy)` в спеке — пример.
- Helper: только stdlib; чистые функции — офлайн-тесты; main-loop и
  live-пробы — не юнит-тестятся (существующая конвенция 16.2).
- Watcher: `set -u`; одно событие на crash (после cooldown-гейта, в
  точке ERR-строки); trim до 100 строк (tmp+mv); под guard
  (юнит не active) — ни kill, ни события.
- Правила репо: english-commits; no-sensitive (никаких приватных IP в
  tracked-файлах); no-cre-hardcode (в новых тестах — существующие
  fake-CRE harness'ы, без литералов `podman`/`podman-remote`); не
  вводить `rm -rf` по переменной (rm-rf-guard) и `pkill -f`
  (pkill-self-guard).
- Containerfile'ы не меняются (хелпер — COPY в
  `nvidia-lact-autoswitch`; пересборка через `make`).
- Команда полного сьют после каждой задачи:
  `for t in scripts/test-*.sh; do sh "$t" || break; done && python3
  scripts/test-lact-autoswitch.py | tail -1` (ожидаемо: все `ok` /
  `# pass=N fail=0`).

---

### Task 0 (координатор, не суб-агент): stage-tag

Правило `stage-tag`: тег на HEAD **до** этапа. Spec/plan-коммиты —
артефакты этапа, точка до этапа — `b19a9ae` (до TODO-переименования
`f676514`). Тег ставится ретроспективно (спека уже в main) —
девиация фиксируется в отчёте этапа.

- [ ] **Step 1: Тег**

```bash
git tag before-stage-027 b19a9ae
git push origin before-stage-027
git tag -l 'before-stage-02*'
```

Expected: `before-stage-026` и `before-stage-027` в списке.

---

### Task 1: Watcher — crash-события в общий файл

**Files:**
- Modify: `scripts/llama-cpp-watcher.sh` (константы верх, `act()`, новая функция)
- Test: `scripts/test-llama-cpp-watcher.sh`

**Interfaces:**
- Consumes: ничего (изолировано).
- Produces: файл `$CRASH_EVENTS_FILE` (дефолт
  `/run/lact-autoswitch/crashes`), строки — целые epoch-секунды,
  по одной на crash-событие; env-override `CRASH_EVENTS_FILE` для
  тестов. Task 3 читает файл через `read_crash_events`.

- [ ] **Step 1: Пишем фейлящие тесты**

В `scripts/test-llama-cpp-watcher.sh`, секция 1 (structural pins),
после строки `check_count "cooldown" ...` (line 54) добавить:

```sh
check_count "crash events file (stage 27)" "$script" 'CRASH_EVENTS_FILE=${CRASH_EVENTS_FILE:-/run/lact-autoswitch/crashes}' 1
check_count "crash events: mkdir events dir" "$script" 'mkdir -p "$(dirname "$CRASH_EVENTS_FILE")"' 1
check_count "crash events: trim 100 (tmp+mv)" "$script" 'tail -n 100 "$CRASH_EVENTS_FILE" > "$CRASH_EVENTS_FILE.tmp"' 1
```

Секция 4 (functional), сразу после `reset_kill_log() { ... }`
(line 105-107, до `run_watcher`), добавить:

```sh
CRASH_EVENTS_FILE=$tmp/crashes
export CRASH_EVENTS_FILE

# desc, expected line count (file absent -> 0)
check_events() {
    desc=$1; want=$2
    if [ -f "$CRASH_EVENTS_FILE" ]; then
        got=$(wc -l < "$CRASH_EVENTS_FILE")
    else
        got=0
    fi
    if [ "$got" -eq "$want" ]; then
        ok "$desc"
    else
        ko "$desc" "$want lines" "$got lines; watcher: $(cat "$tmp/watcher.out" 2>/dev/null)"
    fi
}
```

В конец файла, перед `echo "# pass=$pass fail=$fail"`, добавить:

```sh
# 4.6 crash events (stage 27): паттерн-строка -> 1 epoch-строка
reset_kill_log
rm -f "$CRASH_EVENTS_FILE"
run_watcher "$tmp/lines-pattern.txt" active
check_events "crash events: pattern line -> 1 event" 1

# 4.7 обычные строки -> файла нет
rm -f "$CRASH_EVENTS_FILE"
run_watcher "$tmp/lines-normal.txt" active
check_events "crash events: normal lines -> no file" 0

# 4.8 cooldown-дубли -> 1 событие
rm -f "$CRASH_EVENTS_FILE"
run_watcher "$tmp/lines-double.txt" active
check_events "crash events: duplicate line -> single event" 1

# 4.9 guard: юнит inactive -> ни kill, ни события
reset_kill_log
rm -f "$CRASH_EVENTS_FILE"
run_watcher "$tmp/lines-pattern.txt" inactive
check_kills "guard: unit inactive -> no kill (events)" 0
check_events "guard: unit inactive -> no event" 0

# 4.10 trim: 105 предзаполненных + 1 новое -> 100
seq 1 105 | while read -r n; do echo "$((1786000000 + n))"; done > "$CRASH_EVENTS_FILE"
run_watcher "$tmp/lines-pattern.txt" active
check_events "crash events: trim 106 -> 100" 100
```

- [ ] **Step 2: Прогон — фейл**

Run: `sh scripts/test-llama-cpp-watcher.sh`
Expected: `not ok` на новых structural-пинах (`CRASH_EVENTS_FILE`,
`mkdir -p`, `tail -n 100`) — счётчик fail > 0.

- [ ] **Step 3: Минимальная реализация**

`scripts/llama-cpp-watcher.sh`. После `COOLDOWN=120` (line 24):

```sh
# stage 27: crash-события для pin-политики lact-autoswitch (спека
# 2026-09-03-stage27-pin-safe-design.md §4.1); env-override — тесты
CRASH_EVENTS_FILE=${CRASH_EVENTS_FILE:-/run/lact-autoswitch/crashes}
```

После функции `act()` (line 46), перед `main()`:

```sh
record_crash_event() {
  mkdir -p "$(dirname "$CRASH_EVENTS_FILE")"
  echo "$(date +%s)" >> "$CRASH_EVENTS_FILE"
  tail -n 100 "$CRASH_EVENTS_FILE" > "$CRASH_EVENTS_FILE.tmp"
  mv "$CRASH_EVENTS_FILE.tmp" "$CRASH_EVENTS_FILE"
}
```

В `act()`, между ERR-строкой и `podman kill` (line 39-40):

```sh
  err "zombie-сигнатура в журнале $UNIT: $1"
  record_crash_event
  if podman kill "$CONTAINER" 2>/dev/null; then
```

- [ ] **Step 4: Прогон — зелёный**

Run: `sh scripts/test-llama-cpp-watcher.sh`
Expected: все `ok`, `# pass=N fail=0`.

- [ ] **Step 5: Полный сьют**

Run: команда полного сьют из Global Constraints.
Expected: все тесты зелёные.

- [ ] **Step 6: Коммит**

```bash
git add scripts/llama-cpp-watcher.sh scripts/test-llama-cpp-watcher.sh
git commit -m "watcher: append crash events to /run/lact-autoswitch/crashes (stage 27 pin channel; trim 100, env override, structural+functional tests)"
```

---

### Task 2: Helper — чистые pin-функции (TDD) + сьют в README

**Files:**
- Modify: `resources/driver/lact-autoswitch.py` (env-блок, чистый раздел)
- Test: `scripts/test-lact-autoswitch.py`
- Modify: `README.md` (секция «Тесты»)

**Interfaces:**
- Consumes: ничего.
- Produces (Task 3 использует дословно):
  - константы модуля: `CRASH_PIN_COUNT`, `CRASH_PIN_WINDOW`,
    `THERMAL_PIN_COUNT`, `THERMAL_PIN_WINDOW`, `PIN_LOG_EVERY`,
    `PIN_FILE`, `CRASH_EVENTS_FILE`;
  - `read_crash_events(path, now, window) -> [int]` — ts из
    целочисленных строк, окно `(now-window, now]`, мусор игнорируется,
    файла нет → `[]`;
  - `decide_pin(crash_ts, now, crash_count, crash_window, thermal_ts,
    thermal_count, thermal_window, pinned) -> (bool, reason|None,
    count, int_window)` — приоритет `crashes` над `thermal`; при
    `pinned` → `(False, None, 0, 0)`;
  - `parse_pin_file(path) -> (ts|None, n|None, reason)` —
    missing/пустой/мусор → `(None, None, "external")`, частичный
    парсинг best-effort;
  - `pin_log_due(now, last_block_log, every) -> bool` — `None` →
    `True`, иначе `now - last >= every`;
  - `write_pin_file(path, reason, count, window, ts, n)` — атомарно
    (tmp+`os.replace`), строка `reason=%s count=%d window=%d ts=%d
    n=%d\n`.

- [ ] **Step 1: Пишем фейлящие тесты**

В `scripts/test-lact-autoswitch.py`, в конец `try:`-блока (перед
`finally:`/очисткой tmpd — там, где заканчиваются существующие
`check(...)`), добавить. Уточнение (ruling R5): блок оборачивается в
`try: … except AttributeError as e: ko(pin_desc, "pin functions
defined", "AttributeError: %s" % e)` — конвенция файла (client-shim-блок
обёрнут так же): внешний `try:` без `except`, без guard RED-прогон
погибает traceback'ом до TAP-сводки. 17 чеков внутри — дословно:

```python
# --- stage 27: pin (spec 2026-09-03-stage27-pin-safe-design.md) ---
NOW = 1786000000
CW, TW = 600, 1800

check("decide_pin: below crash threshold",
      m.decide_pin([NOW - 100, NOW - 50], NOW, 3, CW, [], 3, TW, False),
      (False, None, 0, 0))
check("decide_pin: crash threshold reached",
      m.decide_pin([NOW - 100, NOW - 50, NOW - 10], NOW, 3, CW, [], 3, TW, False),
      (True, "crashes", 3, CW))
check("decide_pin: old events outside window",
      m.decide_pin([NOW - 601, NOW - 700, NOW - 800], NOW, 3, CW, [], 3, TW, False),
      (False, None, 0, 0))
check("decide_pin: future ts ignored",
      m.decide_pin([NOW + 5, NOW + 6, NOW + 7], NOW, 3, CW, [], 3, TW, False),
      (False, None, 0, 0))
check("decide_pin: thermal threshold",
      m.decide_pin([], NOW, 3, CW, [NOW - 100, NOW - 50, NOW - 10], 3, TW, False),
      (True, "thermal", 3, TW))
check("decide_pin: crashes priority over thermal",
      m.decide_pin([NOW - 100, NOW - 50, NOW - 10], NOW, 3, CW,
                   [NOW - 100, NOW - 50, NOW - 10], 3, TW, False),
      (True, "crashes", 3, CW))
check("decide_pin: pinned -> no retrigger",
      m.decide_pin([NOW - 100, NOW - 50, NOW - 10], NOW, 3, CW, [], 3, TW, True),
      (False, None, 0, 0))

ev = os.path.join(tmpd, "crashes")
with open(ev, "w") as f:
    f.write("%d\n%d\ngarbage\n%d\n" % (NOW - 100, NOW - 10, NOW - 900))
check("read_crash_events: window + garbage skip",
      m.read_crash_events(ev, NOW, CW), [NOW - 100, NOW - 10])
check("read_crash_events: missing file",
      m.read_crash_events(os.path.join(tmpd, "nope"), NOW, CW), [])

pf = os.path.join(tmpd, "pin")
m.write_pin_file(pf, "crashes", 3, CW, NOW, 2)
check("pin file roundtrip", m.parse_pin_file(pf), (NOW, 2, "crashes"))
with open(pf, "w") as f:
    f.write("")
check("pin file empty -> external", m.parse_pin_file(pf), (None, None, "external"))
check("pin file missing -> external",
      m.parse_pin_file(os.path.join(tmpd, "nope2")), (None, None, "external"))
with open(pf, "w") as f:
    f.write("not a pin line\n")
check("pin file garbage -> external", m.parse_pin_file(pf), (None, None, "external"))
with open(pf, "w") as f:
    f.write("reason=thermal count=3 window=1800 ts=xyz n=bad\n")
check("pin file partial parse", m.parse_pin_file(pf), (None, None, "thermal"))

check("pin_log_due: first", m.pin_log_due(NOW, None, 300), True)
check("pin_log_due: inside interval", m.pin_log_due(NOW, NOW - 100, 300), False)
check("pin_log_due: boundary", m.pin_log_due(NOW, NOW - 300, 300), True)
```

- [ ] **Step 2: Прогон — фейл**

Run: `python3 scripts/test-lact-autoswitch.py`
Expected: `not ok` с `AttributeError: module ... has no attribute
'decide_pin'` и т.п., `# pass=N fail=M` (M > 0).

- [ ] **Step 3: Минимальная реализация**

`resources/driver/lact-autoswitch.py`. В env-блок (после line 36,
`HISTORY_LINES = ...`):

```python
CRASH_PIN_COUNT = int(os.environ.get("CRASH_PIN_COUNT", "3"))
CRASH_PIN_WINDOW = int(os.environ.get("CRASH_PIN_WINDOW", "600"))
THERMAL_PIN_COUNT = int(os.environ.get("THERMAL_PIN_COUNT", "3"))
THERMAL_PIN_WINDOW = int(os.environ.get("THERMAL_PIN_WINDOW", "1800"))
PIN_LOG_EVERY = int(os.environ.get("PIN_LOG_EVERY", "300"))
PIN_FILE = os.environ.get("PIN_FILE", "/run/lact-autoswitch/pin")
CRASH_EVENTS_FILE = os.environ.get(
    "CRASH_EVENTS_FILE", "/run/lact-autoswitch/crashes")
```

В чистый раздел (после `decide_target`, перед `class History`):

```python
def read_crash_events(path, now, window):
    """[ts] integer lines with now-window < ts <= now; missing file ->
    [], non-integer lines ignored (watcher is the only writer)."""
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return []
    out = []
    for line in lines:
        try:
            ts = int(line.strip())
        except ValueError:
            continue
        if now - window < ts <= now:
            out.append(ts)
    return out


def decide_pin(crash_ts, now, crash_count, crash_window,
               thermal_ts, thermal_count, thermal_window, pinned):
    """(pin, reason, count, window); crashes take priority over
    thermal; no retrigger while pinned."""
    if pinned:
        return False, None, 0, 0
    recent_c = [t for t in crash_ts if now - crash_window < t <= now]
    if len(recent_c) >= crash_count:
        return True, "crashes", len(recent_c), crash_window
    recent_t = [t for t in thermal_ts if now - thermal_window < t <= now]
    if len(recent_t) >= thermal_count:
        return True, "thermal", len(recent_t), thermal_window
    return False, None, 0, 0


def parse_pin_file(path):
    """(ts, n, reason) from the pin file; missing/empty/unparseable ->
    (None, None, 'external'); partial parse is best-effort."""
    try:
        with open(path, encoding="utf-8") as f:
            line = f.readline().strip()
    except OSError:
        return None, None, "external"
    if not line:
        return None, None, "external"
    ts, n, reason = None, None, "external"
    for field in line.split():
        k, _, v = field.partition("=")
        if k == "ts":
            try:
                ts = int(v)
            except ValueError:
                pass
        elif k == "n":
            try:
                n = int(v)
            except ValueError:
                pass
        elif k == "reason":
            reason = v
    return ts, n, reason


def pin_log_due(now, last_block_log, every):
    """Block-log rate limit: first immediately, then >= every apart."""
    if last_block_log is None:
        return True
    return now - last_block_log >= every


def write_pin_file(path, reason, count, window, ts, n):
    """Atomic pin write (tmp + os.replace): one 'reason=... count=...
    window=... ts=... n=...' line."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("reason=%s count=%d window=%d ts=%d n=%d\n"
                % (reason, count, window, int(ts), n))
    os.replace(tmp, path)
```

- [ ] **Step 4: Прогон — зелёный**

Run: `python3 scripts/test-lact-autoswitch.py`
Expected: все `ok`, `# pass=N fail=0` (N = 53 + 17 новых = 70).

- [ ] **Step 5: README — .py-тест в сьют**

`README.md`, секция «Тесты»:

```sh
for t in scripts/test-*.sh; do sh "$t" || break; done
python3 scripts/test-lact-autoswitch.py   # LACT-хелпер (TAP)
```

(до этого .py-тест был orphan — не в `.sh`-цикле).

- [ ] **Step 6: Полный сьют**

Run: команда полного сьют из Global Constraints.
Expected: все зелёные.

- [ ] **Step 7: Коммит**

```bash
git add resources/driver/lact-autoswitch.py scripts/test-lact-autoswitch.py README.md
git commit -m "lact-autoswitch: pure pin functions (decide_pin/read_crash_events/parse_pin_file/pin_log_due/write_pin_file) + TAP tests; README suite includes the helper TAP test (stage 27)"
```

---

### Task 3: Helper — pin-состояние в main-loop

**Files:**
- Modify: `docs/superpowers/specs/2026-09-03-stage27-pin-safe-design.md` (аддендум §4.4)
- Modify: `resources/driver/lact-autoswitch.py` (`main()`)

**Interfaces:**
- Consumes: Task 2 (константы + 5 функций, дословно).
- Produces: runtime-поведение по спеке §4.2: pin-файл при триггере,
  ceiling-подавление `Default`, release по исчезновению файла,
  adoption (старт/external), логи §4.4. Hermetic-тестов нет (main-loop
  не юнит-тестится — конвенция 16.2); верификация — live-окно Task 5.

- [ ] **Step 1: Аддендум к спеке (отдельный коммит)**

`docs/superpowers/specs/2026-09-03-stage27-pin-safe-design.md`, §4.4,
блок-строка — заменить:

```
- блок (только для `Default` — единственного OC-профиля;
  `idle`/`safe` не блокируются): `pin: transition to Default blocked
  (load=busy) — fix the root cause: OC under an unresolved issue
  degrades the GPU` (первый — сразу, далее не чаще 1/PIN_LOG_EVERY)
```

на:

```
- блок (только для `Default` — единственного OC-профиля;
  `idle`/`safe` не блокируются): `pin: transition to Default blocked
  (<reason>) — fix the root cause: OC under an unresolved issue
  degrades the GPU`, `<reason>` — причина решения на момент блока
  (`active`, `auth-streak`) (первый — сразу, далее не чаще
  1/PIN_LOG_EVERY)
```

Коммит:

```bash
git add docs/superpowers/specs/2026-09-03-stage27-pin-safe-design.md
git commit -m "docs: stage 27 spec addendum — block log line carries the decision reason (active/auth-streak), ASCII dash in code logs"
```

- [ ] **Step 2: Инициализация pin-состояния в `main()`**

После `lact_down_alarm = False` (line 371):

```python
    pinned = False
    pin_ts = None
    pin_n = 0
    last_block_log = None
    thermal_demotes = []
    engaged_prev = False
```

- [ ] **Step 3: Adoption-функция + adoption при старте**

После `hist.restart_marker(actual0 if actual0 else "-")` (line 377):

```python
    def adopt_pin(where):
        nonlocal pinned, pin_ts, pin_n
        ts, n, _reason = parse_pin_file(PIN_FILE)
        pinned = True
        if ts is not None:
            pin_ts = ts
            log("pin: ACTIVE (%s) age=%dm - safe held"
                % (where, (int(time.time()) - ts) // 60))
        else:
            log("pin: ACTIVE (%s) - safe held" % where)
        if n is not None and n > pin_n:
            pin_n = n

    if os.path.exists(PIN_FILE):
        adopt_pin("adopted at start")
```

- [ ] **Step 4: now_ts + release/external в цикле**

В начале цикла, после `cyc += 1` (line 381):

```python
        now_ts = int(time.time())
```

После блока socket/actual (после line 428, `fb_alarm_armed = True` в
ветке `elif socket_state == "up"`), перед `# --- decide ---`:

```python
        # --- pin: release / external adoption (spec 27) ---
        if pinned and not os.path.exists(PIN_FILE):
            age = "" if pin_ts is None else " (age=%dm)" % (
                (now_ts - pin_ts) // 60)
            log("pin: released%s - actual=%s adopted, switching resumed"
                % (age, actual if actual else "-"))
            pinned = False
            pin_ts = None
        elif not pinned and os.path.exists(PIN_FILE):
            adopt_pin("external")
```

- [ ] **Step 5: Отслеживание терм-демотов**

После `engaged = decide_thermal(...)` (line 431-432):

```python
        if engaged and not engaged_prev:
            thermal_demotes.append(now_ts)
        engaged_prev = engaged
```

- [ ] **Step 6: Триггер pin + ceiling-подавление**

После reason-цепочки (после line 447, `reason = "active"`), перед
`# --- apply ---` (line 449):

```python
        # --- pin trigger + ceiling (spec 27): block Default only ---
        if not pinned:
            crash_ts = read_crash_events(CRASH_EVENTS_FILE, now_ts,
                                         CRASH_PIN_WINDOW)
            do_pin, preason, pcount, pwindow = decide_pin(
                crash_ts, now_ts, CRASH_PIN_COUNT, CRASH_PIN_WINDOW,
                thermal_demotes, THERMAL_PIN_COUNT, THERMAL_PIN_WINDOW,
                False)
            if do_pin:
                pin_n += 1
                write_pin_file(PIN_FILE, preason, pcount, pwindow, now_ts,
                               pin_n)
                pinned = True
                pin_ts = now_ts
                if pin_n > 1:
                    log("pin: re-pin n=%d reason=%s count=%d window=%d - problem persists"
                        % (pin_n, preason, pcount, pwindow))
                else:
                    log("pin: ACTIVE reason=%s count=%d window=%d n=%d - safe held; release: rm %s"
                        % (preason, pcount, pwindow, pin_n, PIN_FILE))
                if up and actual != "safe":
                    okset, detail = apply_profile("safe")
                    if not okset:
                        alarm("pin: apply safe failed: %s" % detail)
        if pinned and target == "Default":
            if pin_log_due(now_ts, last_block_log, PIN_LOG_EVERY):
                log("pin: transition to Default blocked (%s) - fix the root cause: OC under an unresolved issue degrades the GPU"
                    % reason)
                last_block_log = now_ts
            target = "HOLD"
            reason = "pin-blocked"
```

Пояснения для ревьюера (не код):
- crash-файл читается только когда не pinned (триггер неактивен —
  оптимизация; «на каждом POLL» в спеке §4.2 — период выборки
  триггера).
- `thermal_demotes` не чистится по памяти (демоты редкие: цикл ≥ ~5
  мин; окно фильтрует в `decide_pin`).
- При подавлении `Default→HOLD` существующая HOLD-ветка apply
  (release fallback) работает без изменений — семантика 16.2;
  socket-down + pin — краевой случай, профиль при недоступном
  daemon'е пин не контролирует (ограничение, не дефект).
- История (history-строка) при подавлении записывает `HOLD` —
  корректно (фактический target цикла).

- [ ] **Step 7: Синтаксис + полный сьют**

Run: `python3 -m py_compile resources/driver/lact-autoswitch.py && python3 scripts/test-lact-autoswitch.py | tail -1`
Expected: `# pass=70 fail=0` (функции не тронуты).
Run: команда полного сьют из Global Constraints.
Expected: все зелёные.

- [ ] **Step 8: Коммит**

```bash
git add resources/driver/lact-autoswitch.py
git commit -m "lact-autoswitch: pin state in the main loop (crash/thermal triggers, ceiling suppresses Default, release on file rm, adoption at start/external, rate-limited block logs) (stage 27)"
```

---

### Task 4: Деплой — unit `-e`, sysconfig-дефолты, пины тестов

**Files:**
- Modify: `resources/driver/lact-autoswitch.service` (5 `-e` строк)
- Modify: `Makefile` (блок `sysconfig-gen.sh … lact-autoswitch`)
- Test: `scripts/test-systemd-units.sh` (секция 7a)
- Test: `scripts/test-makefile-graph.sh` (секция 1 + syscfg-блок)

**Interfaces:**
- Consumes: Task 2 env-имена (дефолты из Global Constraints).
- Produces: sysconfig `/etc/sysconfig/lact-autoswitch` с 5 новыми
  дефолтами; unit передаёт их в контейнер.

- [ ] **Step 1: Пишем фейлящие пины**

`scripts/test-systemd-units.sh`, секция 7a (после line 196,
`expect_grep "autoswitch: --name" ...`):

```sh
expect_grep "autoswitch: -e CRASH_PIN_COUNT" "$u_autoswitch" '^[[:space:]]*-e CRASH_PIN_COUNT=\$\{CRASH_PIN_COUNT\}[[:space:]]*\\$'
expect_grep "autoswitch: -e CRASH_PIN_WINDOW" "$u_autoswitch" '^[[:space:]]*-e CRASH_PIN_WINDOW=\$\{CRASH_PIN_WINDOW\}[[:space:]]*\\$'
expect_grep "autoswitch: -e THERMAL_PIN_COUNT" "$u_autoswitch" '^[[:space:]]*-e THERMAL_PIN_COUNT=\$\{THERMAL_PIN_COUNT\}[[:space:]]*\\$'
expect_grep "autoswitch: -e THERMAL_PIN_WINDOW" "$u_autoswitch" '^[[:space:]]*-e THERMAL_PIN_WINDOW=\$\{THERMAL_PIN_WINDOW\}[[:space:]]*\\$'
expect_grep "autoswitch: -e PIN_LOG_EVERY" "$u_autoswitch" '^[[:space:]]*-e PIN_LOG_EVERY=\$\{PIN_LOG_EVERY\}[[:space:]]*\\$'
```

`scripts/test-makefile-graph.sh`:
(a) loop секции 1 (line 236-238) — добавить `all` в список:

```sh
for t in all nvidia-base kernel-devel kernel-redist kmod-oss kmod nvidia-redist-drv lact-redist \
         nvidia-xorg nvidia-cuda-devel nvidia-cuda-libs nvidia-nccl-devel \
          nvidia-nccl-libs nvidia-lact nvidia-lact-autoswitch nvidia-nccl llama-cpp-cuda llama-cpp-cuda-debug clean systemd llama-cpp-restart ; do
```

(b) после line 248 (`done` loop'а), до `# --- 2. nvidia-base ---`:

```sh
# --- 1a. all: default goal + exact line ---
first_target=$(grep -m1 -oE '^[A-Za-z0-9_-]+:' "$repo_root/Makefile")
if [ "$first_target" = "all:" ]; then
    ok "all: is the default goal (first target)"
else
    ko "all: is the default goal (first target)" "all:" "$first_target"
fi
if grep -qF 'all: kmod llama-cpp-cuda nvidia-lact-autoswitch systemd' "$repo_root/Makefile"; then
    ok "all: exact target line"
else
    ko "all: exact target line" "all: kmod llama-cpp-cuda nvidia-lact-autoswitch systemd" "not found"
fi
```

(c) syscfg-блок lact-autoswitch (после line 916,
`syscfg "sysconfig lact-autoswitch POLL_INTERVAL" ...`):

```sh
syscfg "sysconfig lact-autoswitch CRASH_PIN_COUNT" "$sys/lact-autoswitch" "CRASH_PIN_COUNT=3"
syscfg "sysconfig lact-autoswitch CRASH_PIN_WINDOW" "$sys/lact-autoswitch" "CRASH_PIN_WINDOW=600"
syscfg "sysconfig lact-autoswitch THERMAL_PIN_COUNT" "$sys/lact-autoswitch" "THERMAL_PIN_COUNT=3"
syscfg "sysconfig lact-autoswitch THERMAL_PIN_WINDOW" "$sys/lact-autoswitch" "THERMAL_PIN_WINDOW=1800"
syscfg "sysconfig lact-autoswitch PIN_LOG_EVERY" "$sys/lact-autoswitch" "PIN_LOG_EVERY=300"
```

- [ ] **Step 2: Прогон — фейл**

Run: `sh scripts/test-systemd-units.sh && sh scripts/test-makefile-graph.sh`
Expected: `not ok` на новых пинах (unit `-e`, syscfg-дефолты);
`all:`-пины — уже зелёные (Makefile поправлен ранее, `5de1b15`).

- [ ] **Step 3: Реализация**

`resources/driver/lact-autoswitch.service` — после строки
`-e KEY_MARKER=${KEY_MARKER} \`:

```
    -e CRASH_PIN_COUNT=${CRASH_PIN_COUNT} \
    -e CRASH_PIN_WINDOW=${CRASH_PIN_WINDOW} \
    -e THERMAL_PIN_COUNT=${THERMAL_PIN_COUNT} \
    -e THERMAL_PIN_WINDOW=${THERMAL_PIN_WINDOW} \
    -e PIN_LOG_EVERY=${PIN_LOG_EVERY} \
```

`Makefile` — в блоке `sysconfig-gen.sh $(HOST_ROOT)/etc/sysconfig
lact-autoswitch` (после `--default POLL_INTERVAL=5 \ `):

```
	  --default CRASH_PIN_COUNT=3 \
	  --default CRASH_PIN_WINDOW=600 \
	  --default THERMAL_PIN_COUNT=3 \
	  --default THERMAL_PIN_WINDOW=1800 \
	  --default PIN_LOG_EVERY=300 \
```

- [ ] **Step 4: Прогон — зелёный**

Run: `sh scripts/test-systemd-units.sh && sh scripts/test-makefile-graph.sh`
Expected: все `ok`, `fail=0`.

- [ ] **Step 5: Полный сьют**

Run: команда полного сьют из Global Constraints.
Expected: все зелёные.

- [ ] **Step 6: Коммит**

```bash
git add resources/driver/lact-autoswitch.service Makefile scripts/test-systemd-units.sh scripts/test-makefile-graph.sh
git commit -m "deploy: lact-autoswitch pin env (unit -e, sysconfig defaults CRASH_PIN_COUNT/WINDOW, THERMAL_PIN_COUNT/WINDOW, PIN_LOG_EVERY) + unit/graph test pins; graph test: all default-goal pins (stage 27)"
```

---

### Task 5: Live-окно — деплой + E2E file-инъекцией (координатор)

Не для суб-агента: живые контейнеры/юниты, присутствие оператора.
Без индукции реальных крашей/перегрева (спека §6).

**Files:**
- Modify: `README.md` (runbook-строка, Step 8)
- Modify: `TODO.md` (чекбоксы Этапа 27)
- Create: `docs/superpowers/reports/2026-09-03-stage27-pin-safe.md` (close-отчёт, правило `close`)

- [ ] **Step 1: Пре-снапшот**

```bash
chroot /run/host /usr/bin/systemctl is-active lact-autoswitch llama-cpp-watcher llama-cpp
ls /run/host/run/lact-autoswitch/ 2>/dev/null
chroot /run/host /usr/bin/journalctl -u lact-autoswitch --since "10 min ago" --no-pager | tail -5
```

Expected: все юниты active; `pin`/`crashes` файлов нет (или записать
факт); журнал без `pin:` строк.

- [ ] **Step 2: Сборка + деплой**

```bash
make nvidia-lact-autoswitch   # COPY-слой хелпера (driver не пересобирается)
make systemd                  # unit + sysconfig + watcher-скрипт на хост
```

Expected: сборка COPY-слоя без дnf-операций; `make systemd` — UNIT-OK
(deploy + enable).

- [ ] **Step 3: Рестарт затронутых юнитов**

```bash
chroot /run/host /usr/bin/systemctl restart lact-autoswitch llama-cpp-watcher
sleep 5
chroot /run/host /usr/bin/systemctl is-active lact-autoswitch llama-cpp-watcher
chroot /run/host /usr/bin/journalctl -u lact-autoswitch --since "1 min ago" --no-pager | tail -10
```

Expected: оба active; в журнале `start: key found ...`, `pin:` строк
нет (pin-файла нет).

- [ ] **Step 4: E2E-1 — ручной pin (touch) + release (rm)**

Активная сессия обязана быть (load=busy) — блок-лог виден.

```bash
chroot /run/host /usr/bin/touch /run/lact-autoswitch/pin
sleep 15
chroot /run/host /usr/bin/journalctl -u lact-autoswitch --since "1 min ago" --no-pager | grep 'pin:'
```

Expected: `pin: ACTIVE (external) - safe held` + (при busy) `pin:
transition to Default blocked (active) - fix the root cause: ...`.

```bash
chroot /run/host /usr/bin/rm -f /run/lact-autoswitch/pin
sleep 15
chroot /run/host /usr/bin/journalctl -u lact-autoswitch --since "1 min ago" --no-pager | grep 'pin:'
```

Expected: `pin: released - actual=... adopted, switching resumed`
(без age — external touch, ts неизвестен).

- [ ] **Step 5: E2E-2 — crash-триггер (фейковые ts)**

```bash
for i in 1 2 3; do chroot /run/host /usr/bin/sh -c "echo \$((\$(date +%s) - $i*10)) >> /run/lact-autoswitch/crashes"; done
sleep 15
chroot /run/host /usr/bin/journalctl -u lact-autoswitch --since "1 min ago" --no-pager | grep 'pin:'
podman-remote exec lact-autoswitch nvidia-smi --query-gpu=power.limit --format=csv,noheader
```

Expected: `pin: ACTIVE reason=crashes count=3 window=600 n=1 - safe
held; release: rm /run/lact-autoswitch/pin`; power.limit = 120.00 W на
всех 5 картах (safe-профиль). ~30 c деградации prod-OC — осознанно
(оператор в курсе).

```bash
chroot /run/host /usr/bin/rm -f /run/lact-autoswitch/pin
chroot /run/host /usr/bin/rm -f /run/lact-autoswitch/crashes
sleep 15
chroot /run/host /usr/bin/journalctl -u lact-autoswitch --since "1 min ago" --no-pager | grep 'pin:'
```

Expected: `pin: released (age=0m) - actual=... adopted, switching
resumed`.

- [ ] **Step 6: E2E-3 — персистентность pin'а через рестарт хелпера**

```bash
chroot /run/host /usr/bin/sh -c 'echo "reason=crashes count=3 window=600 ts=$(date +%s) n=1" > /run/lact-autoswitch/pin'
chroot /run/host /usr/bin/systemctl restart lact-autoswitch
sleep 10
chroot /run/host /usr/bin/journalctl -u lact-autoswitch --since "1 min ago" --no-pager | grep 'pin:'
chroot /run/host /usr/bin/rm -f /run/lact-autoswitch/pin
sleep 10
chroot /run/host /usr/bin/journalctl -u lact-autoswitch --since "1 min ago" --no-pager | grep 'pin:'
```

Expected: после рестарта `pin: ACTIVE (adopted at start) age=0m -
safe held` (pin пережил рестарт — ключевое свойство); после rm —
`pin: released (age=0m) ...`.

- [ ] **Step 7: Финальная проверка**

```bash
chroot /run/host /usr/bin/systemctl is-active lact-autoswitch llama-cpp-watcher llama-cpp
ls /run/host/run/lact-autoswitch/
chroot /run/host /usr/bin/journalctl -u lact-autoswitch --since "10 min ago" --no-pager | grep -v 'pin:' | tail -5
podman-remote exec llama-cpp id
```

Expected: все active; `pin`/`crashes` файлов нет; обычный
`switch:`/`verified:` трафик; `uid=1001001` (non-root не сломан).

- [ ] **Step 8: Runbook-строка (спека §8)**

`README.md`, секция «Развёртывание» — после блока
`make systemd`/«Деплой на хост» (до финальной строки про
`LIVE-SERVER.md`) добавить:

```md
После пересборки driver-стадии (образы kmod/driver/lact):
`systemctl restart nvidia-kmod nvidia-card-setting lact-autoswitch`;
`llama-cpp` — протоколом Этапа 25 (`make llama-cpp-restart
MODE=restart`). Pin `safe` (Этап 27) при этом переживает рестарты
(файл в `/run`).
```

Коммит:

```bash
git add README.md
git commit -m "docs: README runbook line — restart affected units after driver-stage rebuilds (pin survives restarts) (stage 27)"
```

- [ ] **Step 9: TODO + отчёт + коммит**

`TODO.md`: снять галки «Спека» и «План + исполнение» в Этапе 27.
Отчёт `docs/superpowers/reports/2026-09-03-stage27-pin-safe.md`:
пре-снапшот, команды/время, фактические journal-строки E2E-1/2/3,
power.limit-замеры, девиации (ретроспективный stage-tag из Task 0;
`make nvidia-lact-autoswitch` вместо `make llama-cpp-cuda` из спеки
§6 — хелпер только в lact-autoswitch-образе, дешевле), rulings.

```bash
git add TODO.md docs/superpowers/reports/2026-09-03-stage27-pin-safe.md
git commit -m "stage 27 close: live window report (E2E pin/release/persistence via file injection), TODO done"
```

---

## Self-Review (выполнено автором плана)

1. **Spec coverage:** §4.1 watcher — Task 1; §4.2 хелпер (функции) —
   Task 2, (main-loop) — Task 3; §4.3 формат pin-файла — Task 2
   (write/parse); §4.4 логи — Task 3 (+аддендум Step 1); §4.5 деплой —
   Task 4; §5 краевые — покрыты поведением Task 3 (release/external/
   adoption, trim Task 1, guard Task 1 4.9); §6 тесты — Tasks 1-4
   (hermetic) + Task 5 (live); §8 runbook — Task 5 Step 8
   (README «Развёртывание»).
2. **Placeholder scan:** нет TBD/«similar to Task N»; все кодовые шаги
   с дословным кодом.
3. **Type consistency:** `decide_pin` 8 аргументов → 4-кортеж —
   одинаково в Task 2 (tests/impl) и Task 3 (вызов); `parse_pin_file`
   3-кортеж — Task 2/3; `pin_log_due` 3 аргумента — Task 2/3;
   `write_pin_file` 6 аргументов — Task 2/3; env-имена — Global
   Constraints/Task 2/Task 4 совпадают.
