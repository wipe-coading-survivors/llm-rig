# Этап 27 — lact-autoswitch: pin `safe` при crash/thermal-loop

Дата: 2026-09-03. Статус: утверждена (координатор+оператор).

## 1. Контекст и проблема

Два цикла деградации на проде (архив `nvidia-aiml`, расследование Xid 13):

1. **Краш-цикл**: OC включён → крах llama.cpp (Xid 13, compute-сторона) →
   watcher детектит и оживляет (`Restart=always` + kill child) → OC снова →
   крах. Watcher по спеке Этапа 10 §1.7 «всегда рестартит, без
   предохранителя»; §1.8: «Demote в safe-профиль при повторных крахах —
   вне скоупа: удержание — территория Этапа 16».
2. **Термальный цикл**: перегрев (>TEMP_SAFE) → хелпер демотит в `safe`
   → остывание (TIME_SAFE_DUR + delta) → обратно OC → перегрев. Термальный
   цикл опаснее крашового (деградация оборудования, а не инференса).

Корневой разрыв: **ни один компонент не удерживает `safe` после повторных
событий**. Watcher не знает о GPU-профилях (и по хартере не должен:
«владелец профилей GPU — хелпер», спека 16.2 §2); хелпер не знает о
крахах (сигналы: load/thermal/socket). Текущий способ фиксации профиля —
`systemctl stop lact-autoswitch` (хелпер adopts фактический профиль при
старте) — останавливает и мониторинг, и снимается любым рутинным
рестартом.

TODO-история: пункт существовал в llm-rig как
«lact-autoswitch: до-состояние при пересборке драйвера» — однострочная
шифра из каркаса плана Этапа 19 (архив `0af4a50`, 31.08), смысла не
несла; восстановленный смысл — этот документ. Поглощает
«эскалация по числу child-крахов (Этап 10)».

## 2. Цели / не цели

**Цели:**

- После N child-крахов в окне **или** M термальных демотов в окне —
  принудительный pin (предохранитель). Семантика пина — **потолок, а не
  фиксация**: запрещён только переход на `Default` (OC, единственный
  опасный профиль); переходы `idle`/`safe` проходят по обычной логике
  (idle консервативнее safe: `IDLE_PL=100` против PL 120).
- Pin переживает рестарты хелпера и деплой; снимается только явным
  действием оператора (или reboot).
- Оператор видит: что зафиксировано, почему, что именно пин блокирует
  (желание хелпера сменить профиль), как снять.
- Термальный мониторинг работает и во время pin'а.

**Не цели:**

- Автоматическое снятие (auto-expiry) — превратило бы предохранитель в
  самобеглый loop.
- Индуктирование реальных крашей/перегрева в live-окне (drill
  оператора, как 30.08).
- Изменение OC-политики, профилей LACT, `locked` (отклонён в 16.3),
  хартеров watcher'а (жизненный цикл чужих юнитов) и хелпера
  (жизненный цикл контейнеров).
- POLL_INTERVAL 5→10 (отдельный опц.-пункт), stop/restart-hang
  (отдельный пункт).

## 3. Архитектура и решения

**Принципы (без изменений):** владелец профилей GPU — хелпер (16.2 §2);
watcher не управляет юнитами (10 §1); хелпер не управляет контейнерами
(16.2 §2).

**R1. Watcher = донор событий.** Watcher при каждом детекте child-краха
(после cooldown-гейта, в точке ERR-строки) дописывает timestamp в общий
файл событий. Сам pin-решением не занимается.

**R2. Вся pin-политика в хелпере.** Оба триггера (краши, терм-демоты),
пороги, pin-файл, логи — одна точка. Терм-демоты хелпер видит сам; краши —
через файл событий.

**R3. Pin = файл** `/run/lact-autoswitch/pin`. Presence = pin активен
(содержимое — информационное; пустой файл оператора — валидный ручной
pin). Файл переживает рестарт хелпера и деплой; `/run` — tmpfs → reboot
чистит pin и события (допустимо: после перезагрузки состояние свежее,
счётчики копят заново).

**R4. Снятие — явный акт оператора:** `rm /run/lact-autoswitch/pin`
(хелпер подхватывает в течение POLL_INTERVAL). Никакого auto-expiry.
Re-pin после снятия логируется со счётчиком — хроническая проблема
видима в журнале.

**Отклонённые альтернативы:**

- Watcher сам `systemctl stop lact-autoswitch` + применяет safe: ломает
  владельца профилей (GPU-профиль трогает не-хелпер), останавливает
  терм-мониторинг, расширяет хартер watcher'а.
- Pin in-memory + снятие перезапуском хелпера: любой рутинный рестарт
  юнита (деплой, пересборка драйвера) = тихий unpin → неуправляемый
  цикл (решение оператора 03.09: «более правильно отпинивать»).
- Auto-expiry по таймауту: автономный loop — то, что лечим.

## 4. Компоненты и изменения

### 4.1 Watcher (`scripts/llama-cpp-watcher.sh`)

- Точка записи: после cooldown-гейта и guard, в той же точке, где
  пишется ERR-строка (одна строка на crash-событие; burst-повторы
  поглощены cooldown'ом 120 s).
- Действие: `mkdir -p` каталога + append целого epoch-секунды в
  `$CRASH_EVENTS_FILE` (дефолт `/run/lact-autoswitch/crashes`, env
  override для hermetic-тестов) + trim файла до последних 100 строк
  (tmp+mv, атомарно).
- Не читает, не решает, не логирует дополнительно (ERR-строка — и есть
  аудит).

### 4.2 Хелпер (`resources/driver/lact-autoswitch.py`)

Новые env (все с дефолтами, оператор крутит через sysconfig):

| env | дефолт | смысл |
|---|---|---|
| `CRASH_PIN_COUNT` | 3 | крашей в окне → pin |
| `CRASH_PIN_WINDOW` | 600 | окно, с |
| `THERMAL_PIN_COUNT` | 3 | терм-демотов в окне → pin |
| `THERMAL_PIN_WINDOW` | 1800 | окно, с |
| `PIN_LOG_EVERY` | 300 | rate-limit блок-логов, с |
| `PIN_FILE` | `/run/lact-autoswitch/pin` | pin-файл (env для тестов) |
| `CRASH_EVENTS_FILE` | `/run/lact-autoswitch/crashes` | файл событий (env для тестов) |

Логика (новые чистые функции — TDD-тестируемы, в стиле §6.1 спеки 16.2):

- `decide_pin(crash_ts, now, count, window, thermal_ts, t_count, t_window,
  pinned)` → `(pin: bool, reason: str|None)` — пороговое решение;
  reason: `crashes` при срабатывании крашового триггера иначе `thermal`;
  при `pinned` — не триггерится повторно.
- Crash-сигнал: чтение файла на каждом POLL (5 s): целочисленные строки,
  мусорные игнорируются; считаем `ts > now - CRASH_PIN_WINDOW`.
- Терм-сигнал: in-memory очередь timestamp'ов термальных переходов в
  `safe` (существующий engage-путь `decide_thermal`), чистится окном.
- Триггер (не pinned): написать pin-файл (tmp+mv, атомарно),
  `actual != safe` → `apply_profile("safe")`, `pinned=True`,
  `n = 1` (или предыдущий+1 при re-pin в этом жизненном цикле).
- Во время pin (каждый POLL): файла нет → **release** (лог,
  `pinned=False`, дальше — обычный цикл, adopt фактического профиля
  существующим механизмом следующей пробы). Файл есть → computed target
  из обычного decision-loop; если это **переход на `Default` (OC)** —
  transition подавляется (target := HOLD, держим текущий), блок-лог по
  rate-limit; переходы `idle`/`safe`/`FALLBACK`/`HOLD` проходят по
  обычной логике (пин — потолок, не фиксация); если computed не
  требует Default — пин «спит», молчим (не спамим при idle-прохладном).
- Внешний pin: файл появился mid-run (оператор `touch`) → хелпер входит
  в pinned на следующем POLL (лог «external») — ручной pin без стопа
  юнита, мониторинг жив.
- Старт: pin-файл существует → adoption: `pinned=True`, лог с age
  (ts из файла, best-effort), pin пережил рестарт.

### 4.3 Формат pin-файла

Одна строка: `reason=<crashes|thermal> count=<k> window=<s> ts=<epoch>
n=<int>`. Хелпер пишет; оператор только `rm`. Пустой/непарсебельный
файл = pin активен (reason «external»), парсинг best-effort.

### 4.4 Логи (journal, стиль хелпера: англ., lowercase, `prefix:`)

- pin: `pin: ACTIVE reason=crashes count=3 window=600 n=1 — safe held;
  release: rm /run/lact-autoswitch/pin`
- adoption: `pin: ACTIVE (adopted at start) age=42m — safe held` /
  `pin: ACTIVE (external) — safe held` (release-команда — та же, что в
  строке pin; в логе повторяется только в строке pin)
- блок (только для `Default` — единственного OC-профиля;
  `idle`/`safe` не блокируются): `pin: transition to Default blocked
  (load=busy) — fix the root cause: OC under an unresolved issue
  degrades the GPU` (первый — сразу, далее не чаще 1/PIN_LOG_EVERY)
- снятие: `pin: released (age=42m) — actual=safe adopted, switching
  resumed` (age = now−ts из файла; опускается, если ts неизвестен —
  внешний pin с пустым/мусорным содержимым)
- re-pin: `pin: re-pin n=2 reason=thermal count=3 window=1800 — problem
  persists`

### 4.5 Деплой

- `resources/driver/lact-autoswitch.service`: +5 строк `-e`
  (`CRASH_PIN_COUNT`, `CRASH_PIN_WINDOW`, `THERMAL_PIN_COUNT`,
  `THERMAL_PIN_WINDOW`, `PIN_LOG_EVERY`); пути `PIN_FILE`/
  `CRASH_EVENTS_FILE` — дефолты хелпера, в юнит не передаются.
  Остальное юнита не трогается.
- `Makefile`: блок `sysconfig-gen.sh … lact-autoswitch` +5 `--default`.
- SELinux: каталог уже bind-монтажен в контейнер с `:z` +
  `--security-opt label=disable`; хостовой watcher пишет напрямую —
  без новых требований.
- Изображения: `nvidia-lact-autoswitch` — пересборка COPY-слоя.

## 5. Краевые случаи

| случай | поведение |
|---|---|
| watcher down | новых crash-событий нет; pin держится (файл), терм-триггер работает |
| хелпер down | pin-файл инертен (профиль в последнем состоянии), мониторинга нет — как и сегодня |
| reboot | pin+события смыты (tmpfs); состояние свежее, счётчики заново |
| ручной pin оператора (`touch`) | хелпер adopt'ит (старт/mid-run), лог external |
| ручной `lact.sh apply` во время pin'а | живёт до первого перехода (16.2 §2); non-OC-переходы разрешены пин'ом, OC-переходов нет |
| pin + idle | переход на `idle` разрешён (консервативнее safe) |
| pin + термический штиль / computed не требует Default | пин «спит», логов нет |
| чужой writer в файл событий | root-хост может запинить GPU — допустимо (root и так всё может) |
| crash-файл | trim 100 строк watcher'ом; окно 600 s ≪ 100 событий |

## 6. Тесты

**Hermetic (TDD, RED→GREEN, стиль репо):**

- `scripts/test-llama-cpp-watcher.sh`: новые кейсы — append epoch в
  `$CRASH_EVENTS_FILE` (env, tmp) при детекте; trim 105→100; нет append
  в cooldown; `mkdir -p` несуществующего каталога.
- `scripts/test-lact-autoswitch.py`: новые чистые функции —
  `decide_pin` (2/3 события, окно-истечение, терм-порог, приоритет
  reason, no-retrigger при pinned), парсинг pin-файла (валидный/пустой/
  мусор → external), rate-limit блок-лога.
- `test-makefile-graph.sh`: пины 5 новых sysconfig-дефолтов
  lact-autoswitch в deploy-loop.
- `test-systemd-units.sh`: пины 5 новых `-e`.
- `test-no-sensitive`: без новых литералов (в спеке — без IP).
- `README.md` «Тесты»: добавить в сьют `python3
  scripts/test-lact-autoswitch.py` (сейчас .py-тест orphan — не в
  `.sh`-цикле).

**Live-окно** (деплой + E2E file-инъекцией, без индукции):

1. `make llama-cpp-cuda` (COPY-слой) + `make systemd` + restart
   `lact-autoswitch` + `llama-cpp-watcher` юнитов.
2. База: хелпер up, pin-файла нет, journal чист, crash-файла нет.
3. E2E-1 (ручной pin): активная сессия (busy) → `touch` pin → ≤2 POLL:
   «ACTIVE (external)» + «transition to Default blocked» → `rm` →
   «released», switch в Default.
4. E2E-2 (crash-триггер): 3 свежих epoch в crash-файл → «ACTIVE
   reason=crashes count=3», PL/fan = значения safe-профиля (сверка
   nvidia-smi) → `rm` → released.
5. E2E-3 (персистентность): `touch` pin → `systemctl restart
   lact-autoswitch` → «ACTIVE (adopted at start)» — pin пережил
   рестарт → `rm`.

## 7. Риски

- **R1.** Pin блокирует OC → потеря перфа до снятия — задумано
  (предохранитель); снятие — 1 команда, в логе при pin'е.
- **R2.** Python-хелпер в образе — пересборка COPY-слоя, быстро;
  watcher-скрипт — хостовой, restart тривиален.
- **R3.** Формат crash-файла — новый контракт watcher→хелпер;
  парсинг best-effort (мусор игнорируется) — деградация, а не поломка.
- **R4.** Часы: epoch-секунды, один хост, контейнер с общим часами —
  skew отсутствует.

## 8. Runbook (хвост исходного TODO-пункта)

В `README.md` (секция «Развёртывание») или `LIVE-SERVER.md` — строка:
«После пересборки driver-стадии (kmod/driver/lact образы):
`systemctl restart nvidia-kmod nvidia-card-setting lact-autoswitch`;
`llama-cpp` — протоколом Этапа 25 (`make llama-cpp-restart MODE=restart`).
Pin `safe` при этом переживает рестарты (файл в `/run`)».
