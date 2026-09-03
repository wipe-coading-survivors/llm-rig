# llama-cpp non-root Implementation Plan (Этап 26)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Запуск прод-контейнера `llama-cpp` non-root без `--privileged`
(`-u ${LLAMA_UID}:0`, `-m ${LLAMA_MEM}`, `--ulimit memlock`, devices,
маунт `/llama`) + пины/док + live-окно с приёмкой и замерами памяти.

**Architecture:** Изменения — юнит (podman-флаги), Makefile-таргет
`systemd` (sysconfig-дефолты + guarded chmod keys), debug-скрипты
(рипл live ini), тест-пины, `LIVE-SERVER.md`. Containerfile, watcher,
restart-скрипт — без изменений. Live-окно — операционный протокол на
живом сервере (координатор, НЕ суб-агент: рестарт убивает нашу сессию).

**Tech Stack:** systemd-юнит podman, Makefile (CRE-конвенция),
POSIX-sh тесты (ok/ko), host: 5×RTX 3060, cgroup v2.

**Spec:** `docs/superpowers/specs/2026-09-03-llama-cpp-nonroot-design.md`
(читать вместе с этим планом; факты F1–F16, риски R1–R7, протокол
live-окна — там).

## Global Constraints

- Правила репо (`AGENTS.md`): `no-cre-hardcode`, `english-commits`,
  `verify-before-fix`, `rm-rf-guard`, `pkill-self-guard`.
- Значения (спека §2/§4): `LLAMA_UID=1001001`, `LLAMA_MEM=120g`
  (стартовое; оператор поднимает при OOM — F8), `LLAMA_SHM_SIZE=1g`.
- Тестовые скрипты: `#!/bin/sh`, ok/ko-функции, счётчики
  `pass`/`fail`, финал `echo "# pass=$pass fail=$fail"; [ "$fail" -eq 0 ]`.
- Запуск тестов — из корня репо: `sh scripts/test-<имя>.sh`.
- Коммиты — английский, стиль репо (`feat: ...` / `docs: ...`).
- НЕ трогать: `*.containerfile`, `scripts/llama-cpp-watcher.sh`,
  `scripts/llama-cpp-restart.sh`, `resources/driver/*`,
  `debug/llama-cpu-stub.ini`, `debug/llama.ini` (не используется, 0
  ссылок — спека §4), `debug/repro-llama-block3-run.sh` кроме C2-launch
  (2 строки), `lact-autoswitch` (остаётся `--privileged`).

---

### Task 1: `llama-cpp.service` non-root + пины юнита

**Files:**
- Modify: `resources/llama/llama-cpp.service` (ExecStart, строки 12–25)
- Test: `scripts/test-systemd-units.sh` (секция «6. llama-cpp.service»,
  строки 164–178)

**Interfaces:**
- Consumes: ничего (первая задача).
- Produces: юнит с флагами `-u ${LLAMA_UID}:0`, `-m ${LLAMA_MEM}`,
  `--ulimit memlock=-1:-1`, `--device /dev/nvidiactl`,
  `--device /dev/nvidia-uvm`, маунт `/etc/llama:/llama:ro`,
  `--models-preset /llama/llama.ini`; без `--privileged`. Task 2
  полагается на то, что sysconfig-ключи `LLAMA_UID`/`LLAMA_MEM`
  потребованы юнитом (их дефолты ставит Task 2).

- [ ] **Step 1: Обновить тест (failing)**

В `scripts/test-systemd-units.sh` заменить блок:

```sh
expect_grep "llama: /etc/llama mount" "$u_llama" '^[[:space:]]*-v /etc/llama:/root/llama:ro[[:space:]]*\\$'
expect_grep "llama: Restart=always" "$u_llama" '^Restart=always$'
```

на:

```sh
expect_grep "llama: /etc/llama mount" "$u_llama" '^[[:space:]]*-v /etc/llama:/llama:ro[[:space:]]*\\$'
expect_grep "llama: user from sysconfig" "$u_llama" '^[[:space:]]*-u \${LLAMA_UID}:0[[:space:]]*\\$'
expect_grep "llama: memory from sysconfig" "$u_llama" '^[[:space:]]*-m \${LLAMA_MEM}[[:space:]]*\\$'
expect_grep "llama: memlock ulimit" "$u_llama" '^[[:space:]]*--ulimit memlock=-1:-1[[:space:]]*\\$'
expect_grep "llama: nvidiactl device" "$u_llama" '^[[:space:]]*--device /dev/nvidiactl[[:space:]]*\\$'
expect_grep "llama: nvidia-uvm device" "$u_llama" '^[[:space:]]*--device /dev/nvidia-uvm[[:space:]]*\\$'
expect_grep "llama: models-preset /llama" "$u_llama" '\-\-models-preset /llama/llama\.ini'
expect_no_grep "llama: no --privileged" "$u_llama" '(^|[[:space:]])--privileged([[:space:]]|$)'
expect_grep "llama: Restart=always" "$u_llama" '^Restart=always$'
```

Остальные пины секции 6 (`Requires mount`, `EnvironmentFile`, `--name`,
`ExecStartPre`, image, shm-size, порт, `Restart=always`, негативные) —
без изменений.

- [ ] **Step 2: Прогнать тест — ожидаем FAIL**

Run: `sh scripts/test-systemd-units.sh`
Expected: `not ok` по 8 строкам (mount `/llama`, user, memory, memlock,
nvidiactl, nvidia-uvm, preset `/llama`, no `--privileged`); секция
`systemd-analyze verify` — `ok` (старый юнит валиден); финал
`fail>0`, rc≠0.

- [ ] **Step 3: Обновить юнит**

`resources/llama/llama-cpp.service` — весь файл в итоге:

```ini
[Unit]
Description=Podman container llama.cpp CUDA server (multi-GPU, NCCL)
After=network-online.target nvidia-kmod.service nvidia-card-setting.service var-local-llm.mount
Wants=network-online.target nvidia-kmod.service nvidia-card-setting.service
Requires=var-local-llm.mount
RequiresMountsFor=/run/containers/storage

[Service]
Environment=PODMAN_SYSTEMD_UNIT=%n
EnvironmentFile=/etc/sysconfig/llama-cpp
ExecStartPre=-/usr/bin/podman rm -f llama-cpp
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
Restart=always
RestartSec=30
Type=simple

[Install]
WantedBy=default.target
```

- [ ] **Step 4: Прогнать тест — ожидаем PASS**

Run: `sh scripts/test-systemd-units.sh`
Expected: все `ok`, `fail=0`, rc=0 (включая `systemd-analyze verify:
5 artifacts, no warnings`).

- [ ] **Step 5: Commit**

```bash
git add resources/llama/llama-cpp.service scripts/test-systemd-units.sh
git commit -m "feat: llama-cpp.service — non-root run (no --privileged; -u/-m/memlock, nvidiactl+nvidia-uvm devices, /llama mount+preset) + unit pins"
```

---

### Task 2: Makefile `systemd` (sysconfig-дефолты + keys chmod) + graph-пины

**Files:**
- Modify: `Makefile` (таргет `systemd`, блок sysconfig-gen llama-cpp —
  строки 395–399)
- Test: `scripts/test-makefile-graph.sh` (секция «19. systemd»:
  hostroot-подготовка ~812–830, syscfg-пины ~923–926)

**Interfaces:**
- Consumes: `$(LLAMA_KEYS_FILE)` (уже определена в Makefile, строка 46:
  `/etc/llama/llama-cpp-keys.txt`), `$(HOST_ROOT)`.
- Produces: host sysconfig `llama-cpp` с ключами `LLAMA_UID=1001001`,
  `LLAMA_MEM=120g`, `LLAMA_SHM_SIZE=1g` (для Task 5 live-окно); keys-
  файл на хосте mode 640.

- [ ] **Step 1: Обновить graph-тест (failing)**

В `scripts/test-makefile-graph.sh`:

(a) после строки
`printf 'LLAMA_HOST = 127.0.0.1\nLLM_NFS_SERVER = 127.0.0.1\n' > "$repo_root/local.mk"`
(подготовка local.mk-стаба, ~строка 828) и ПЕРЕД `make_target systemd
HOST_ROOT="$tmp/hostroot" SYSTEMDCTL="$tmp/fake-systemctl"` вставить:

```sh
mkdir -p "$tmp/hostroot/etc/llama"
printf 'test-key\n' > "$tmp/hostroot/etc/llama/llama-cpp-keys.txt"
chmod 600 "$tmp/hostroot/etc/llama/llama-cpp-keys.txt"
```

(b) заменить строку:

```sh
syscfg "sysconfig llama-cpp LLAMA_SHM_SIZE" "$sys/llama-cpp" "LLAMA_SHM_SIZE=64g"
```

на блок:

```sh
syscfg "sysconfig llama-cpp LLAMA_SHM_SIZE" "$sys/llama-cpp" "LLAMA_SHM_SIZE=1g"
syscfg "sysconfig llama-cpp LLAMA_UID" "$sys/llama-cpp" "LLAMA_UID=1001001"
syscfg "sysconfig llama-cpp LLAMA_MEM" "$sys/llama-cpp" "LLAMA_MEM=120g"
keys="$tmp/hostroot/etc/llama/llama-cpp-keys.txt"
if [ "$(stat -c %a "$keys" 2>/dev/null || echo absent)" = "640" ]; then
    ok "systemd: keys chmod 600 -> 640"
else
    ko "systemd: keys chmod 600 -> 640" "640" "$(stat -c %a "$keys" 2>/dev/null || echo absent)"
fi
```

- [ ] **Step 2: Прогнать тест — ожидаем FAIL**

Run: `sh scripts/test-makefile-graph.sh`
Expected: `not ok` по 4 строкам (SHM `1g`, `LLAMA_UID`, `LLAMA_MEM`,
`keys chmod`); остальные секции — как были. Тест длинный (fake-сборки),
это нормально.

- [ ] **Step 3: Обновить Makefile**

В таргете `systemd` заменить:

```make
	$(CURDIR)/scripts/sysconfig-gen.sh $(HOST_ROOT)/etc/sysconfig llama-cpp \
	  --build LLAMA_IMAGE=$(LLAMA_CPP_IMAGE) \
	  --default LLAMA_LOG_TIMESTAMPS=1 \
	  --default LLAMA_PORT=$(LLAMA_PORT) \
	  --default LLAMA_SHM_SIZE=64g
	$(SYSTEMDCTL) daemon-reload
```

на:

```make
	$(CURDIR)/scripts/sysconfig-gen.sh $(HOST_ROOT)/etc/sysconfig llama-cpp \
	  --build LLAMA_IMAGE=$(LLAMA_CPP_IMAGE) \
	  --default LLAMA_LOG_TIMESTAMPS=1 \
	  --default LLAMA_PORT=$(LLAMA_PORT) \
	  --default LLAMA_SHM_SIZE=1g \
	  --default LLAMA_UID=1001001 \
	  --default LLAMA_MEM=120g
	if [ -f $(HOST_ROOT)$(LLAMA_KEYS_FILE) ] ; then chmod 640 $(HOST_ROOT)$(LLAMA_KEYS_FILE) ; fi
	$(SYSTEMDCTL) daemon-reload
```

(один таб в начале каждой строки рецепта; `if` — одна строка без
продолжений: guard не падает при отсутствии файла — F15.)

- [ ] **Step 4: Прогнать тест — ожидаем PASS**

Run: `sh scripts/test-makefile-graph.sh`
Expected: все `ok`, включая `systemd rc=0`, 4 новых строки, и
fail-loud-секция (`systemd fail-loud rc=2 (no local.mk)`).

- [ ] **Step 5: Commit**

```bash
git add Makefile scripts/test-makefile-graph.sh
git commit -m "feat: Makefile systemd — sysconfig defaults LLAMA_UID=1001001/LLAMA_MEM=120g/LLAMA_SHM_SIZE=1g + guarded idempotent keys chmod 640; graph pins"
```

---

### Task 3: Debug-скрипты (рипл live ini) + пины

**Files:**
- Modify: `debug/llama-run.sh` (ExecStart-блок, строки 11–20)
- Modify: `debug/repro-llama-block3-run.sh` (только C2-launch, строки
  424 и 427 — 2 строки)
- Test: `scripts/test-debug-scripts.sh` (строки 39, 41, 49)

**Interfaces:**
- Consumes: live ini на хосте с `api-key-file = /llama/llama-cpp-keys.txt`
  (права в Task 5; до этого debug-скрипты не исполняются на живом
  хосте — только статические пины).
- Produces: ничего для других задач (завершающая статическая задача).

- [ ] **Step 1: Обновить тест (failing)**

В `scripts/test-debug-scripts.sh`:

(a) заменить строку:

```sh
check_count "llama-run.sh: /etc/llama mount" "$run" '-v /etc/llama:/root/llama:ro' 1
```

на:

```sh
check_count "llama-run.sh: /etc/llama mount" "$run" '-v /etc/llama:/llama:ro' 1
```

(b) заменить строку:

```sh
check_count "llama-run.sh: shm-size 64g" "$run" '--shm-size=64g' 1
```

на блок:

```sh
check_count "llama-run.sh: shm-size 1g" "$run" '--shm-size=1g' 1
check_count "llama-run.sh: non-root user" "$run" '-u 1001001:0' 1
check_count "llama-run.sh: memory limit 120g" "$run" '-m 120g' 1
check_count "llama-run.sh: memlock ulimit" "$run" '--ulimit memlock=-1:-1' 1
check_count "llama-run.sh: nvidiactl device" "$run" '--device /dev/nvidiactl' 1
check_count "llama-run.sh: nvidia-uvm device" "$run" '--device /dev/nvidia-uvm' 1
check_count "llama-run.sh: no --privileged" "$run" '--privileged' 0
check_count "llama-run.sh: models-preset /llama" "$run" '--models-preset /llama/llama.ini' 1
```

(c) заменить строку:

```sh
check_count "repro: /etc/llama mounts x3" "$repro" '-v /etc/llama:/root/llama:ro' 3
```

на:

```sh
check_count "repro: /etc/llama mount /llama (C2)" "$repro" '-v /etc/llama:/llama:ro' 1
check_count "repro: /etc/llama mounts /root/llama (stubs x2)" "$repro" '-v /etc/llama:/root/llama:ro' 2
```

(остальные строки секций — без изменений; stub-маунты `/root/llama`
в plain/router формах repro НЕ трогаем — они со своим ini/явными
args, F13.)

- [ ] **Step 2: Прогнать тест — ожидаем FAIL**

Run: `sh scripts/test-debug-scripts.sh`
Expected: `not ok` по ~11 строкам (llama-run: mount, shm 1g, user,
memory, memlock, nvidiactl, nvidia-uvm, no --privileged, preset;
repro: /llama count, /root/llama count); `bash -n` — `ok`.

- [ ] **Step 3: Обновить `debug/llama-run.sh`**

Весь файл в итоге (header-комментарий без изменений):

```bash
#!/bin/bash
# Production llama-server (llama-cpp-cuda) — manual fallback for the
# llama-cpp.service unit (the unit is the canonical prod command).
# Named container + rm -f before run mirror the unit ExecStartPre
# (reproducible restart, equivalent to the unit also for an existing
# container). No GPU pin: thermal balancing is covered by
# LACT per-card OC.
CRE=podman
[ -f /run/.containerenv ] && CRE=podman-remote
$CRE rm -f llama-cpp
exec $CRE run -d --name llama-cpp \
  --device /dev/nvidia0 --device /dev/nvidia1 --device /dev/nvidia2 \
  --device /dev/nvidia3 --device /dev/nvidia4 \
  --device /dev/nvidiactl --device /dev/nvidia-uvm \
  --security-opt label=disable --shm-size=1g \
  -u 1001001:0 -m 120g \
  --ulimit memlock=-1:-1 \
  -v /var/local/llm/gguf-models:/models \
  -v /etc/llama:/llama:ro \
  -p 8080:8080 \
  -e LLAMA_LOG_TIMESTAMPS=1 \
  localhost/llama-cpp-cuda:13.3 --port 8080 --host 0.0.0.0 \
  --models-preset /llama/llama.ini
```

(значения зашиты — стиль файла; mirror юнита Task 1; `no-cre-hardcode`:
CRE-detection на строках 8–9 сохранён.)

- [ ] **Step 4: Обновить C2-launch в `debug/repro-llama-block3-run.sh`**

Только 2 строки в C2-блоке (строки ~424 и ~427):

```
        -v /var/local/llm/gguf-models:/models -v /etc/llama:/llama:ro \
```
(было `-v /etc/llama:/root/llama:ro`)

```
        --models-preset /llama/llama.ini >> "$OUT" 2>&1; then
```
(было `--models-preset /root/llama/llama.ini`)

`--privileged` и `--shm-size=64g` в этом блоке — без изменений
(debug-контейнер, спека §4).

- [ ] **Step 5: Прогнать тест — ожидаем PASS**

Run: `sh scripts/test-debug-scripts.sh`
Expected: все `ok`, `fail=0`, rc=0.

- [ ] **Step 6: Commit**

```bash
git add debug/llama-run.sh debug/repro-llama-block3-run.sh scripts/test-debug-scripts.sh
git commit -m "feat: debug scripts — /llama mount+preset ripple (llama-run.sh full non-root mirror, repro C2), pins"
```

---

### Task 4: `LIVE-SERVER.md` (топология + ключи)

**Files:**
- Modify: `LIVE-SERVER.md` (секция «Топология и факты» — первый
  буллет, строки 9–12; буллет «Ключи», строки 29–32)

**Interfaces:**
- Consumes: результат Task 1 (флаги юнита).
- Produces: док для оператора до live-окна; секция «Числа»
  заполняется в Task 5.

- [ ] **Step 1: Обновить первый буллет «Топология и факты»**

Заменить:

```
- Роутер: контейнер `llama-cpp` (юнит `llama-cpp.service`), порт 8080
  (`-p ${LLAMA_PORT}:8080`), `--models-preset /root/llama/llama.ini`.
  Инстанс — единственный потомок pid 1; его порт наружу не
  опубликован: все сигналы — через роутер.
```

на:

```
- Роутер: контейнер `llama-cpp` (юнит `llama-cpp.service`), порт 8080
  (`-p ${LLAMA_PORT}:8080`), non-root `-u ${LLAMA_UID}:0` (gid 0
  читает keys `640 root:root` и `/dev/nvidia*` `660 root:root`),
  без `--privileged` (devices: `nvidia0-4` + `nvidiactl` +
  `nvidia-uvm`), `-m ${LLAMA_MEM}` (стартовое 120g; при OOM оператор
  поднимает в sysconfig — потребление растёт с накопленным
  трафиком), `--ulimit memlock=-1:-1` (mlock-модель),
  `--shm-size ${LLAMA_SHM_SIZE}` (1g; NCCL/CUDA IPC ~185M),
  `--models-preset /llama/llama.ini` (маунт `/etc/llama:/llama:ro`).
  Инстанс — единственный потомок pid 1; его порт наружу не
  опубликован: все сигналы — через роутер.
```

- [ ] **Step 2: Обновить буллет «Ключи»**

Заменить:

```
- Ключи: хостовый `/etc/llama/llama-cpp-keys.txt` (файл с `#`-
  комментариями и пустыми строками; рабочая строка — первая из
  не-комментариев). Читаются в рантайме; **не писать в логи/argv**
  (no-sensitive), без `curl -v` на keyed-эндпоинтах.
```

на:

```
- Ключи: хостовый `/etc/llama/llama-cpp-keys.txt` (mode `640 root:root`
  — gid 0 читает, контейнер non-root; `make systemd` ставит 640
  idempotent-шагом; файл с `#`-комментариями и пустыми строками;
  рабочая строка — первая из не-комментариев). Читаются в рантайме;
  **не писать в логи/argv** (no-sensitive), без `curl -v` на
  keyed-эндпоинтах.
```

- [ ] **Step 3: Проверить отсутствие прочих `/root/llama` в файле**

Run: `grep -n '/root/llama' LIVE-SERVER.md`
Expected: нет совпадений.

- [ ] **Step 4: Commit**

```bash
git add LIVE-SERVER.md
git commit -m "docs: LIVE-SERVER — non-root topology (user/devices/limits, /llama mount, shm 1g), keys mode 640"
```

---

### Task 5: Live-окно + отчёт + TODO.md (ТОЛЬКО координатор)

**Files:**
- Create: `docs/superpowers/reports/2026-09-03-stage26-llama-cpp-nonroot.md`
- Modify: `LIVE-SERVER.md` (секция «Числа» — замеры), `TODO.md` (Этап 26)

**Interfaces:**
- Consumes: результат Task 1–4 (ветка `stage26-llama-cpp-nonroot`
  зелёная).
- Produces: закрытие этапа; merge в `main` (finishing-a-development-
  branch).

**ВАЖНО:** эта задача исполняется **координатором напрямую, без
диспатча суб-агента**: `MODE=restart` убивает opencode-сессию на
этом сервере (R5; по дизайну Этапа 25 — `setsid -f` + status-файл,
координатор опрашивает status). Прочитать `LIVE-SERVER.md` целиком
перед первым шагом (правило `AGENTS.md`).

- [ ] **Step 1: Pre-снимки + check**

```bash
mkdir -p /tmp/llm-rig/stage26
podman-remote inspect llama-cpp > /tmp/llm-rig/stage26/pre-inspect.json
cp /run/host/etc/sysconfig/llama-cpp /tmp/llm-rig/stage26/pre-sysconfig
cp /run/host/etc/llama/llama.ini /tmp/llm-rig/stage26/pre-ini
stat -c '%a %U:%G' /run/host/etc/llama/llama-cpp-keys.txt > /tmp/llm-rig/stage26/pre-keys-mode
podman-remote stats llama-cpp --no-stream > /tmp/llm-rig/stage26/pre-stats.txt
git status --short && git log --oneline -6
make llama-cpp-restart MODE=check
```

Expected: check — SAME_HOST=yes, модель loaded (опрос status-файла
`/tmp/llm-rig/llama-cpp-restart.status` до финальной строки).

- [ ] **Step 2: Deploy**

```bash
make systemd
diff /run/host/etc/systemd/system/llama-cpp.service resources/llama/llama-cpp.service && echo UNIT-OK
grep -E '^(LLAMA_UID|LLAMA_MEM|LLAMA_SHM_SIZE)=' /run/host/etc/sysconfig/llama-cpp
stat -c %a /run/host/etc/llama/llama-cpp-keys.txt
```

Expected: `UNIT-OK`; sysconfig: `LLAMA_UID=1001001`, `LLAMA_MEM=120g`,
`LLAMA_SHM_SIZE=64g` (one-shot — следующий шаг); keys mode `640`.

- [ ] **Step 3: Host-правки (one-shot)**

```bash
sed -i 's/^LLAMA_SHM_SIZE=64g$/LLAMA_SHM_SIZE=1g/' /run/host/etc/sysconfig/llama-cpp
sed -i 's|/root/llama/llama-cpp-keys.txt|/llama/llama-cpp-keys.txt|' /run/host/etc/llama/llama.ini
grep '^LLAMA_SHM_SIZE=' /run/host/etc/sysconfig/llama-cpp
grep 'api-key-file' /run/host/etc/llama/llama.ini
```

Expected: `LLAMA_SHM_SIZE=1g`; `api-key-file = /llama/llama-cpp-keys.txt`.

- [ ] **Step 4: Restart (сессия умрёт — по дизайну)**

```bash
make llama-cpp-restart MODE=restart
```

Опрос `/tmp/llm-rig/llama-cpp-restart.status` (повторные чтения между
шагами) до финальной строки `done rc=0` / `failed rc=<N>`. При
`failed rc=5` (wait-ready) — сначала диагностика: oom-строки
(Step 6), caps/seccomp (R1/R2).

- [ ] **Step 5: Приёмка (read-only + exec)**

```bash
podman-remote exec llama-cpp id
podman-remote exec llama-cpp df -h /dev/shm | tail -1
podman-remote stats llama-cpp --no-stream
podman-remote exec llama-cpp grep 'Max locked memory' /proc/1/limits
curl -s http://127.0.0.1:8080/v1/models | jq '.data[0].status.value'
```

Expected: `uid=1001001(1001001) gid=0(root)`; shm `1.0G`; memlock
`unlimited` (у pid 1 контейнера = ulimit всего контейнера; PID-
неймспейс у контейнера свой — host pid из `exec ps` не читать);
`loaded`. Keyed-эндпоинты — verify-запрос
`llama-cpp-restart.sh` (POST 200, rc=0 в status). Записать baseline
памяти: `podman stats` + cgroup (F16):

```bash
cid=$(podman-remote inspect llama-cpp --format '{{.Id}}')
cg=/run/host/sys/fs/cgroup/machine.slice/libpod-$cid.scope
cat $cg/memory.current
grep -E '^(anon|file) ' $cg/memory.stat
```

- [ ] **Step 6: OOM-протокол (если упал / упадёт в окне; R3/R7)**

```bash
chroot /run/host /usr/bin/journalctl --since "-30 min" | grep -iE 'oom|killed process'
```

Зафиксировать: момент, `memory.current` в момент падения, нагрузку
(сессии). Далее: `make llama-cpp-restart MODE=stop` (если crash loop),
`sed -i 's/^LLAMA_MEM=120g$/LLAMA_MEM=<X>g/' /run/host/etc/sysconfig/llama-cpp`
(операторское значение по факту), `make llama-cpp-restart MODE=restart`.
Не отказ этапа — финальное значение `LLAMA_MEM` — зона оператора
(решение 03.09).

- [ ] **Step 7: Динамика памяти**

Перезамеры Step 5 (stats + cgroup) с интервалами 30–60 мин до конца
окна: рост anon с трафиком — ожидаемо (F8), фиксируется в отчёте.

- [ ] **Step 8: Отчёт**

`docs/superpowers/reports/2026-09-03-stage26-llama-cpp-nonroot.md`:
протокол + результаты (pre-снимки, приёмка по пунктам Step 5,
baseline/динамика памяти с разбором anon/file, OOM-точки если были,
использованные fallback'и R1/R2 если были). Стиль — по отчётам Этапов
24/25.

- [ ] **Step 9: `LIVE-SERVER.md` «Числа» + `TODO.md`**

`LIVE-SERVER.md`, секция «Числа»: добавить блок замеров Этапа 26
(baseline памяти при пустом пуле, динамика, OOM-точка если была).

`TODO.md`, секция «### 26. llama-cpp non-root» — весь блок в итоге
(отметить чекбоксы, поправить `LLAMA_MEM=150g` → `120g`, добавить
ссылки):

```md
### 26. llama-cpp non-root

Решение (03.09): откат на root build/deploy/debug (rootful toolbx) —
из «Non-root окружения» оставляем только запуск контейнера `llama-cpp`
non-root (`-u ${LLAMA_UID}:0`, без `--privileged`).

Спека: `docs/superpowers/specs/2026-09-03-llama-cpp-nonroot-design.md`
- [x] `llama-cpp.service`: снять `--privileged`; добавить
      `-u ${LLAMA_UID}:0`, `-m ${LLAMA_MEM}`, `--ulimit memlock=-1:-1`
      (модель mlock), `--device nvidiactl/nvidia-uvm`; маунт
      `/etc/llama:/llama:ro` + `--models-preset /llama/llama.ini`
- [x] keys `/etc/llama/llama-cpp-keys.txt`: `chmod 640` (root:root,
      group 0 читает) — idempotent-шаг в `make systemd`
- [x] sysconfig `llama-cpp`: `LLAMA_UID=1001001`, `LLAMA_MEM=120g`
      (стартовое; при OOM оператор поднимает — рост с трафиком,
      отчёт §память), `LLAMA_SHM_SIZE=1g` (было 64g; факт 185M =
      NCCL/CUDA IPC)
- [x] `test-systemd-units.sh` (pin новых флагов), `LIVE-SERVER.md`
      (non-root + цифры памяти); containerfile — без изменений
      (`/app` уже 755)
- [x] live-окно: safe-restart → `podman exec llama-cpp id` = non-root,
      keyed-эндпоинты, GPU/model-load, memlock, замеры памяти (отчёт
      `docs/superpowers/reports/2026-09-03-stage26-llama-cpp-nonroot.md`)

Отменено (откат на root): non-root-dev, привилегии через `sudo`,
container-registry (ghcr/локальный).
```

- [ ] **Step 10: Полный тест-сьют**

Run (из корня репо, по одному, каждый должен пройти):

```bash
for t in scripts/test-*.sh; do echo "== $t"; sh "$t" || echo "FAIL: $t"; done
python3 scripts/test-lact-autoswitch.py
```

Expected: все `fail=0` / rc=0 (особенно `test-systemd-units.sh`,
`test-makefile-graph.sh`, `test-debug-scripts.sh`, `test-no-sensitive.sh`).

- [ ] **Step 11: Commit + finishing**

```bash
git add docs/superpowers/reports/2026-09-03-stage26-llama-cpp-nonroot.md LIVE-SERVER.md TODO.md
git commit -m "docs: stage 26 live window report (non-root acceptance, memory baseline/trend), LIVE-SERVER numbers, TODO done"
```

Затем — superpowers:finishing-a-development-branch: merge
`stage26-llama-cpp-nonroot` → `main` (паттерн Этапа 25: PR).
