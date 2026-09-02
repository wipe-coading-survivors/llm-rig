# Stage 25 Safe Live-Server Restart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** безопасный рестарт/стоп/старт живого llama-cpp-сервера из opencode-сессии, которую обслуживает тот же сервер: `scripts/llama-cpp-restart.sh` (self-healing через `setsid -f`), Makefile-таргет, `LIVE-SERVER.md` + правило в `AGENTS.md`.

**Architecture:** скрипт (bash, `set -u`) берёт значения из env (выставляет Makefile-таргет) либо дефолтов; preflight (юнит/контейнер/ключи) + вердикт SAME_HOST (opencode baseURL + CRE-контейнер + порт) → wait-idle (поллинг `/slots`, `is_processing`) → `systemctl restart` (via `SYSTEMDCTL`, chroot при toolbx) → wait-ready (`/health` + `/v1/models` loaded) → verify-curl. Status-файл — протокол опроса координатора. Тесты: hermetic (mock-сервер + PATH-stubs) + pin в graph-тесте.

**Tech Stack:** bash, GNU Make, python3 (mock в тесте), curl, flock, setsid; POSIX-тест-скрипты репо (`scripts/test-*.sh`, ok/ko-конвенция).

**Spec:** `docs/superpowers/specs/2026-09-02-safe-restart-design.md` (раунд ревью 1 применён, 02.09.2026). Факты F1–F14 — в спеке; ссылки ниже на факты/секции спеки.

## Global Constraints

- **no-cre-hardcode:** `CRE` в скрипте — дефолт `podman` + `-remote`, если существует `/run/.containerenv` (как в Makefile); тесты не хардкодят инструмент — stub через PATH/env.
- **rm-rf-guard:** `rm -rf` по пути из переменной — только через `scripts/safe-rm --under`; в скрипте `rm -rf` нет вообще (только `rm -f` на конкретные файлы); tmp каталог теста — через safe-rm.
- **pkill-self-guard:** `pkill -f`/`killall` не используются (в тесте — kill по PID).
- **english-commits:** сообщения коммитов — на английском.
- **Makefile-формат:** continuation-строки — TAB + 2 пробела; команда — с одного TAB (пин 21a в graph-тесте).
- **no-sensitive:** API-ключ — только из файла в рантайме, в `Authorization: Bearer` заголовке; ни в логах, ни в status, ни в argv, ни в tracked-файлах (без `curl -v` на keyed-эндпоинтах). `scripts/test-no-sensitive.sh` — зелёный после каждой задачи.
- **Одно-модельный сервер (F13):** все проверки покрывают модель из `$LLAMA_MODEL`; много-модельный сервер — вне скоупа (YAGNI).
- **Ссылки** в `AGENTS.md`/`LIVE-SERVER.md`/`TODO.md`/`COORDINATOR.md` — **по именам секций/файлов, не по номерам** (внутри плана/спеки — по параграфам допустимо).
- **Зелёный сьют** после каждой задачи: все `scripts/test-*.sh` завершаются `fail=0` (после Task 1 — 14 шт.).
- **Live-окно — вне плана** (отдельная фаза после выполнения, по спеке, секция «Live-окно»: check → in-flight abort → полный рестарт с таймлайном; приёмка — сессия переживает рестарт).
- Среда: сборка/тесты — в toolbx `t-ocode` на хосте `pigoky`; `CRE=podman-remote`, `HOST_ROOT=/run/host`. Живой прод-сервер — **не трогать** в задачах плана (все прогоны против mock).

---

### Task 1: `scripts/llama-cpp-restart.sh` + hermetic-тест (TDD)

**Files:**
- Create: `scripts/test-llama-cpp-restart.sh`
- Create: `scripts/llama-cpp-restart.sh`

**Interfaces:**
- Consumes: ничего из других задач (самодостаточен; значения — env/аргументы).
- Produces: `scripts/llama-cpp-restart.sh <check|restart|stop|start> [--idle-timeout N] [--ready-timeout N] [--model M] [--verify-request TEXT]`; env-контракт: `CRE`, `HOST_ROOT`, `SYSTEMDCTL`, `LLAMA_URL`, `LLAMA_MODEL`, `LLAMA_KEYS_FILE`, `LLAMA_CONTAINER`, `LLAMA_UNIT`, `STATUS`, `OPENCODE_CONFIG`. rc: 0 ok; 2 preflight/usage/lock; 3 wait-idle; 4 systemctl; 5 wait-ready; 6 verify. Status-файл: строки `<ts> <state> <detail>`, финал `done rc=0` / `failed rc=<N> <reason>`. Task 2 передаёт ровно эти env из Makefile.

- [ ] **Step 1: Написать hermetic-тест `scripts/test-llama-cpp-restart.sh`**

```sh
#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
pass=0
fail=0

ok() { pass=$((pass + 1)); echo "ok - $1"; }
ko() { fail=$((fail + 1)); echo "not ok - $1"; echo "  expected: $2"; echo "  actual:   $3"; }

script="$repo_root/scripts/llama-cpp-restart.sh"
tmp=$(mktemp -d /tmp/test-llama-cpp-restart.XXXXXX)
mock_pid=
trap '
    if [ -n "${mock_pid:-}" ]; then kill "$mock_pid" 2>/dev/null || true; fi
    "$repo_root/scripts/safe-rm" --under /tmp "$tmp" 2>/dev/null || true
' EXIT INT TERM

port=18791
state=$tmp/state
mkdir -p "$state"

# --- mock server: /health, /v1/models, /slots, /v1/chat/completions ---
cat > "$tmp/mock.py" <<'PY'
import http.server
import json
import os
import sys

port = int(sys.argv[1])
state = sys.argv[2]

def flag(name):
    return os.path.exists(os.path.join(state, name))

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        # компактный JSON — как у реального llama-server (grep-пины без пробелов)
        body = json.dumps(obj, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            if flag("ready"):
                self._send(200, {"status": "ok"})
            else:
                self._send(503, {"status": "loading"})
        elif self.path == "/v1/models":
            if flag("ready"):
                self._send(200, {"data": [{"id": "default",
                                           "aliases": [],
                                           "status": {"value": "loaded"}}]})
            else:
                self._send(200, {"data": []})
        elif self.path.startswith("/slots"):
            if flag("busy"):
                slots = [{"id": 0, "is_processing": True, "id_task": 1},
                         {"id": 1, "is_processing": False, "id_task": 2}]
            else:
                slots = [{"id": 0, "is_processing": False, "id_task": 1},
                         {"id": 1, "is_processing": False, "id_task": 2}]
            self._send(200, slots)
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/v1/chat/completions":
            if self.headers.get("Authorization", "") != "Bearer test-key-123":
                self._send(401, {"error": "bad key"})
                return
            length = int(self.headers.get("Content-Length", 0))
            self.rfile.read(length)
            self._send(200, {"choices": [{"message": {"content": "ok"}}]})
        else:
            self._send(404, {"error": "not found"})

http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
PY
python3 "$tmp/mock.py" "$port" "$state" &
mock_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if curl -fsS "http://127.0.0.1:$port/v1/models" > /dev/null 2>&1; then break; fi
    sleep 0.1
done
curl -fsS "http://127.0.0.1:$port/v1/models" > /dev/null

# --- PATH stubs: podman (ps/inspect), systemctl (calls log, ready toggle) ---
bin=$tmp/bin
mkdir -p "$bin"
cat > "$bin/podman" <<SH
#!/bin/sh
case "\$1" in
ps)
    [ -f "$state/container" ] && echo llama-cpp
    ;;
inspect)
    echo $port
    ;;
esac
exit 0
SH
chmod +x "$bin/podman"
cat > "$bin/systemctl" <<SH
#!/bin/sh
echo "systemctl \$*" >> "$state/systemctl-calls"
case "\$1" in
is-active)
    if [ -f "$state/unit-active" ]; then echo active; else echo inactive; fi
    ;;
restart|start)
    rm -f "$state/ready"
    ( sleep 2; touch "$state/ready" ) &
    ;;
stop)
    rm -f "$state/ready"
    ;;
esac
exit 0
SH
chmod +x "$bin/systemctl"

# --- fixtures: keys file (comments/blank lines), opencode config ---
cat > "$tmp/keys.txt" <<'EOF'
# comment line

test-key-123
EOF
mkdir -p "$tmp/home/.config/opencode"
write_cfg() { # $1 = port for baseURL
    printf '{"provider":{"p":{"options":{"baseURL":"http://127.0.0.1:%s/v1"}}}}\n' \
        "$1" > "$tmp/home/.config/opencode/opencode.jsonc"
}
write_cfg "$port"

OVR_OPENCODE_CONFIG=
run_script() { # args to the script; log -> $tmp/run.log, status -> $tmp/run.status
    env CRE=podman HOST_ROOT= SYSTEMDCTL=systemctl \
        LLAMA_URL="http://127.0.0.1:$port" LLAMA_MODEL=default \
        LLAMA_KEYS_FILE="$tmp/keys.txt" LLAMA_CONTAINER=llama-cpp \
        STATUS="$tmp/run.status" OPENCODE_CONFIG="$OVR_OPENCODE_CONFIG" \
        HOME="$tmp/home" \
        PATH="$bin:$PATH" \
        bash "$script" "$@" > "$tmp/run.log" 2>&1
}

# --- 1. syntax ---
if bash -n "$script"; then
    ok "llama-cpp-restart.sh: bash -n"
else
    ko "llama-cpp-restart.sh: bash -n" "rc=0" "syntax error"
fi

# --- 2. usage: bad mode -> rc=2 ---
rc=0
run_script bogus || rc=$?
if [ "$rc" -eq 2 ]; then
    ok "usage: bad mode rc=2"
else
    ko "usage: bad mode rc=2" "rc=2" "rc=$rc"
fi

# --- 3. check: all green, same-host yes ---
touch "$state/container" "$state/unit-active" "$state/ready"
rm -f "$state/busy" "$state/systemctl-calls"
rc=0
run_script check || rc=$?
if [ "$rc" -eq 0 ]; then
    ok "check rc=0"
else
    ko "check rc=0" "rc=0" "rc=$rc log: $(cat "$tmp/run.log")"
fi
for line in ' start pid=' ' preflight ok' ' same-host yes' \
            ' check slots busy=0' ' check model loaded' ' done rc=0'; do
    if grep -qF -- "$line" "$tmp/run.status"; then
        ok "check status:$line"
    else
        ko "check status:$line" "line in $tmp/run.status" "$(cat "$tmp/run.status")"
    fi
done

# --- 4. check: same-host no (config port mismatch) ---
write_cfg 9999
rc=0
run_script check || rc=$?
if [ "$rc" -eq 0 ] && grep -qF ' same-host no' "$tmp/run.status"; then
    ok "check same-host no (port mismatch)"
else
    ko "check same-host no (port mismatch)" "same-host no" "$(cat "$tmp/run.status")"
fi
write_cfg "$port"

# --- 5. check: OPENCODE_CONFIG override ---
printf '{"provider":{"p":{"options":{"baseURL":"http://127.0.0.1:%s/v1"}}}}\n' \
    "$port" > "$tmp/other-config.json"
OVR_OPENCODE_CONFIG="$tmp/other-config.json"
rc=0
run_script check || rc=$?
if [ "$rc" -eq 0 ] && grep -qF ' same-host yes' "$tmp/run.status"; then
    ok "check same-host yes (OPENCODE_CONFIG override)"
else
    ko "check same-host yes (OPENCODE_CONFIG override)" "same-host yes" "$(cat "$tmp/run.status")"
fi
OVR_OPENCODE_CONFIG=

# --- 6. restart: in-flight abort (rc=3, systemctl NOT called) ---
rm -f "$state/systemctl-calls"
touch "$state/busy"
rc=0
run_script restart --idle-timeout 2 || rc=$?
if [ "$rc" -eq 3 ]; then
    ok "restart in-flight rc=3"
else
    ko "restart in-flight rc=3" "rc=3" "rc=$rc log: $(cat "$tmp/run.log")"
fi
if grep -qF ' failed rc=3 ' "$tmp/run.status"; then
    ok "restart in-flight status failed rc=3"
else
    ko "restart in-flight status failed rc=3" "line in status" "$(cat "$tmp/run.status")"
fi
if [ -e "$state/systemctl-calls" ] && grep -qx 'systemctl restart llama-cpp' "$state/systemctl-calls"; then
    ko "restart in-flight: no systemctl restart" "no 'systemctl restart llama-cpp' call" "$(cat "$state/systemctl-calls")"
else
    ok "restart in-flight: no systemctl restart"
fi
if [ -f "$state/ready" ]; then
    ok "restart in-flight: server untouched"
else
    ko "restart in-flight: server untouched" "ready flag present" "absent"
fi
rm -f "$state/busy"

# --- 7. restart: full flow (busy -> idle -> restart -> ready -> verify) ---
rm -f "$state/systemctl-calls"
touch "$state/busy"
( sleep 3; rm -f "$state/busy" ) &
waiter=$!
rc=0
run_script restart --idle-timeout 20 || rc=$?
wait "$waiter"
if [ "$rc" -eq 0 ]; then
    ok "restart full rc=0"
else
    ko "restart full rc=0" "rc=0" "rc=$rc log: $(cat "$tmp/run.log")"
fi
restarts=$(grep -cx 'systemctl restart llama-cpp' "$state/systemctl-calls" || true)
if [ "$restarts" = 1 ]; then
    ok "restart full: systemctl restart exactly once"
else
    ko "restart full: systemctl restart exactly once" "1" "$restarts"
fi
for line in ' wait-idle idle' ' restarting via unit llama-cpp' \
            ' wait-ready model loaded' ' verifying 200 OK' ' done rc=0'; do
    if grep -qF -- "$line" "$tmp/run.status"; then
        ok "restart full status:$line"
    else
        ko "restart full status:$line" "line in $tmp/run.status" "$(cat "$tmp/run.status")"
    fi
done

# --- 8. key never in log/status ---
if grep -qF 'test-key-123' "$tmp/run.status" "$tmp/run.log"; then
    ko "key not in log/status" "no test-key-123" "$(grep -nF test-key-123 "$tmp/run.status" "$tmp/run.log")"
else
    ok "key not in log/status"
fi

# --- 9. flock: second run aborts with rc=2 ---
flock "$tmp/run.status" -c 'sleep 3' &
lockpid=$!
sleep 0.3
rc=0
run_script check || rc=$?
if [ "$rc" -eq 2 ]; then
    ok "flock: second run rc=2"
else
    ko "flock: second run rc=2" "rc=2" "rc=$rc log: $(cat "$tmp/run.log")"
fi
wait "$lockpid"

echo "# pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Запустить тест — убедиться, что красный (скрипта нет)**

Run: `bash scripts/test-llama-cpp-restart.sh`
Expected: FAIL — `bash -n` падает (файл отсутствует), `fail > 0`.

- [ ] **Step 3: Написать `scripts/llama-cpp-restart.sh`**

```bash
#!/bin/bash
# llama-cpp-restart.sh — безопасный restart/stop/start прод llama-cpp-сервера
# из сессии, которую обслуживает тот же сервер (Этап 25).
#
# Self-healing: запуск через `setsid -f` из `make llama-cpp-restart` —
# скрипт переживает сессию/таймаут tool-вызова и доводит сервер до
# готовности; координатор опрашивает STATUS-файл.
# Протокол (states, rc-таблица) и операционные факты: LIVE-SERVER.md.
# Одно-модельный сервер (спека F13): проверки покрывают модель $LLAMA_MODEL.
set -u

usage() {
    echo "usage: llama-cpp-restart.sh <check|restart|stop|start> [--idle-timeout N] [--ready-timeout N] [--model M] [--verify-request TEXT]" >&2
    exit 2
}

# --- значения: env (выставляет Makefile-таргет) либо дефолты ---
# `-` (не `:-`): пустое значение из env осмысленно (HOST_ROOT= — «не в toolbx»).
CRE=${CRE-$(echo -n podman; [ -e /run/.containerenv ] && echo -remote)}
HOST_ROOT=${HOST_ROOT-$([ -e /run/.containerenv ] && echo /run/host)}
if [ -n "$HOST_ROOT" ]; then
    SYSTEMDCTL=${SYSTEMDCTL-chroot $HOST_ROOT /usr/bin/systemctl}
else
    SYSTEMDCTL=${SYSTEMDCTL-systemctl}
fi
LLAMA_URL=${LLAMA_URL-http://127.0.0.1:8080}
LLAMA_MODEL=${LLAMA_MODEL-default}
LLAMA_KEYS_FILE=${LLAMA_KEYS_FILE-/etc/llama/llama-cpp-keys.txt}
LLAMA_CONTAINER=${LLAMA_CONTAINER-llama-cpp}
LLAMA_UNIT=${LLAMA_UNIT-llama-cpp}
STATUS=${STATUS-/tmp/llm-rig/llama-cpp-restart.status}
OPENCODE_CONFIG=${OPENCODE_CONFIG-}

MODE=restart
IDLE_TIMEOUT=30
READY_TIMEOUT=600
VERIFY_REQUEST='Ответь одним словом: ок'
while [ $# -gt 0 ]; do
    case $1 in
    check|restart|stop|start) MODE=$1; shift ;;
    --idle-timeout)   [ $# -ge 2 ] || usage; IDLE_TIMEOUT=$2; shift 2 ;;
    --ready-timeout)  [ $# -ge 2 ] || usage; READY_TIMEOUT=$2; shift 2 ;;
    --model)          [ $# -ge 2 ] || usage; LLAMA_MODEL=$2; shift 2 ;;
    --verify-request) [ $# -ge 2 ] || usage; VERIFY_REQUEST=$2; shift 2 ;;
    *) usage ;;
    esac
done

# --- status-файл + lock (протокол: LIVE-SERVER.md, секция «Рестарт / стоп / старт») ---
mkdir -p "$(dirname "$STATUS")"
exec 9>>"$STATUS"
if ! flock -n 9; then
    echo "[$(date '+%F %T')] ERR: lock: другой запуск в прогрессе (status: $STATUS)" >&2
    exit 2
fi
: > "$STATUS"
BODY_FILE="$STATUS.body"
rm -f "$BODY_FILE"

st() { # $1=state $2=detail; строка: <ts> <state> <detail>
    echo "$(date '+%F %T') $1 $2" >> "$STATUS"
    echo "[$(date '+%F %T')] $1 $2"
}
done_ok() { st done "rc=0"; exit 0; }
fail() { st failed "rc=$1 ${*:2}"; exit "$1"; }

# --- ключ: только из файла в рантайме; в логи/argv не попадает ---
KEYS_PATH=$LLAMA_KEYS_FILE
[ -n "$HOST_ROOT" ] && KEYS_PATH="$HOST_ROOT$LLAMA_KEYS_FILE"
KEY=
read_key() {
    [ -r "$KEYS_PATH" ] || return 1
    KEY=$(grep -vE '^[[:space:]]*(#|$)' "$KEYS_PATH" | head -1)
    [ -n "$KEY" ]
}

# --- HTTP-хелперы: тело -> $BODY_FILE, код -> $HTTP_CODE ---
get() { # $1=path $2=key(1/0)
    local -a a=(-sS -m 15 -o "$BODY_FILE" -w '%{http_code}' "$LLAMA_URL$1")
    [ "${2:-0}" = 1 ] && a+=(-H "Authorization: Bearer $KEY")
    HTTP_CODE=$(curl "${a[@]}") || HTTP_CODE=000
}
post_json() { # $1=path $2=json (keyed)
    HTTP_CODE=$(curl -sS -m 120 -o "$BODY_FILE" -w '%{http_code}' -X POST \
        -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
        -d "$2" "$LLAMA_URL$1") || HTTP_CODE=000
}

container_running() {
    $CRE ps --format '{{.Names}}' 2>/dev/null | grep -qx "$LLAMA_CONTAINER"
}

# --- SAME_HOST (спека, секция «Правило SAME_HOST») ---
SAME_HOST=unknown
same_host_check() {
    local cfg="" c port match=no h p baseurls
    port=${LLAMA_URL##*:}
    if [ -n "$OPENCODE_CONFIG" ]; then
        [ -r "$OPENCODE_CONFIG" ] && cfg=$OPENCODE_CONFIG
    else
        for c in ./opencode.json ./opencode.jsonc \
                 "$HOME/.config/opencode/opencode.json" "$HOME/.config/opencode/opencode.jsonc"; do
            [ -r "$c" ] && { cfg=$c; break; }
        done
    fi
    [ -n "$cfg" ] || { SAME_HOST=unknown; return 0; }
    baseurls=$(grep -oE '"baseURL"[[:space:]]*:[[:space:]]*"[^"]+"' "$cfg" \
        | sed -E 's/.*"https?:\/\/([^:/]+):([0-9]+).*/\1 \2/' || true)
    while read -r h p; do
        [ -n "${h:-}" ] || continue
        case $h in
        127.0.0.1|localhost|::1) [ "${p:-}" = "$port" ] && match=yes ;;
        esac
    done <<< "$baseurls"
    local cond2=no cond3=no cport
    container_running && cond2=yes
    if [ "$cond2" = yes ]; then
        cport=$($CRE inspect --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostPort}} {{end}}{{end}}' "$LLAMA_CONTAINER" 2>/dev/null | tr -d '[:space:]')
        [ "$cport" = "$port" ] && cond3=yes
    fi
    if [ "$match" = yes ] && [ "$cond2" = yes ] && [ "$cond3" = yes ]; then
        SAME_HOST=yes
    elif [ "$match" = no ]; then
        SAME_HOST=no
    else
        SAME_HOST=unknown
    fi
}

preflight() {
    local unit_state
    unit_state=$($SYSTEMDCTL is-active "$LLAMA_UNIT" 2>/dev/null | head -1) || true
    case $MODE in
    restart|stop)
        { [ "$unit_state" = active ] || [ "$unit_state" = activating ]; } \
            || fail 2 "unit $LLAMA_UNIT is '$unit_state' (осознанный стоп/обслуживание)"
        ;;
    start)
        { [ "$unit_state" = inactive ] || [ "$unit_state" = failed ]; } \
            || fail 2 "unit $LLAMA_UNIT is '$unit_state' (ожидался остановленный)"
        ;;
    esac
    if container_running; then
        [ "$MODE" = start ] && fail 2 "container $LLAMA_CONTAINER уже запущен"
    else
        { [ "$MODE" = restart ] || [ "$MODE" = stop ]; } \
            && fail 2 "container $LLAMA_CONTAINER не запущен"
    fi
    read_key || fail 2 "ключи нечитаемы: $KEYS_PATH"
    st preflight "ok unit=$unit_state"
}

wait_idle() {
    st wait-idle "timeout=${IDLE_TIMEOUT}s model=$LLAMA_MODEL"
    local deadline=$(( $(date +%s) + IDLE_TIMEOUT ))
    local slots busy
    while :; do
        if slots=$(curl -sS -m 10 -H "Authorization: Bearer $KEY" "$LLAMA_URL/slots?model=$LLAMA_MODEL" 2>/dev/null); then
            busy=$(grep -o '"is_processing":true' <<< "$slots" | wc -l)
            if [ "$busy" -eq 0 ]; then
                st wait-idle "idle"
                return 0
            fi
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            fail 3 "in-flight: слоты заняты ${IDLE_TIMEOUT}s (abort без форса)"
        fi
        sleep 1
    done
}

wait_ready() {
    st wait-ready "timeout=${READY_TIMEOUT}s model=$LLAMA_MODEL"
    local deadline=$(( $(date +%s) + READY_TIMEOUT ))
    local health models
    while :; do
        get /health 0
        health=$HTTP_CODE
        get /v1/models 0
        models=$(cat "$BODY_FILE")
        if [ "$health" = 200 ] \
            && grep -q "\"id\":\"$LLAMA_MODEL\"" <<< "$models" \
            && grep -q '"value":"loaded"' <<< "$models"; then
            st wait-ready "model loaded"
            return 0
        fi
        [ "$(date +%s)" -ge "$deadline" ] && fail 5 "не готов ${READY_TIMEOUT}s (health=$health)"
        sleep 1
    done
}

verify() {
    st verifying "model=$LLAMA_MODEL"
    local payload
    payload=$(printf '{"model":"%s","messages":[{"role":"user","content":"%s"}],"max_tokens":8}' \
        "$LLAMA_MODEL" "${VERIFY_REQUEST//\"/\\\"}")
    post_json /v1/chat/completions "$payload"
    [ "$HTTP_CODE" = 200 ] || fail 6 "verify http=$HTTP_CODE"
    st verifying "200 OK"
}

check_mode() {
    local slots busy models
    if ! slots=$(curl -sS -m 10 -H "Authorization: Bearer $KEY" "$LLAMA_URL/slots?model=$LLAMA_MODEL" 2>/dev/null); then
        fail 2 "slots недоступны"
    fi
    busy=$(grep -o '"is_processing":true' <<< "$slots" | wc -l)
    st check "slots busy=$busy"
    get /v1/models 0
    models=$(cat "$BODY_FILE")
    if grep -q "\"id\":\"$LLAMA_MODEL\"" <<< "$models" && grep -q '"value":"loaded"' <<< "$models"; then
        st check "model loaded"
    else
        st check "model NOT loaded"
    fi
    done_ok
}

main() {
    st start "pid=$$ mode=$MODE url=$LLAMA_URL model=$LLAMA_MODEL"
    preflight
    if [ "$MODE" = check ] || [ "$MODE" = restart ]; then
        same_host_check
        st same-host "$SAME_HOST"
    fi
    case $MODE in
    check)
        check_mode
        ;;
    restart)
        wait_idle
        st restarting "via unit $LLAMA_UNIT"
        $SYSTEMDCTL restart "$LLAMA_UNIT" || fail 4 "systemctl restart rc=$?"
        wait_ready
        verify
        done_ok
        ;;
    stop)
        wait_idle
        st stopping "via unit $LLAMA_UNIT"
        $SYSTEMDCTL stop "$LLAMA_UNIT" || fail 4 "systemctl stop rc=$?"
        done_ok
        ;;
    start)
        st starting "via unit $LLAMA_UNIT"
        $SYSTEMDCTL start "$LLAMA_UNIT" || fail 4 "systemctl start rc=$?"
        wait_ready
        verify
        done_ok
        ;;
    esac
}
main
```

После записи: `chmod 0755 scripts/llama-cpp-restart.sh`.

- [ ] **Step 4: Запустить тест — убедиться, что зелёный**

Run: `bash scripts/test-llama-cpp-restart.sh`
Expected: `# pass=N fail=0`, rc=0. (Сценарий 7 занимает ~8 c: busy 3 c + ready 2 c — не таймаут, а штатный ход.)

Если красный — чинить скрипт (не тест), перепроверять, пока `fail=0`.

- [ ] **Step 5: Полный тест-сьют зелёный**

Run: `for t in scripts/test-*.sh; do echo "== $t"; bash "$t" || break; done`
Expected: каждый скрипт — `# pass=... fail=0` (14 шт.).

- [ ] **Step 6: Commit**

```bash
git add scripts/llama-cpp-restart.sh scripts/test-llama-cpp-restart.sh
git commit -m "feat: llama-cpp-restart.sh (check/restart/stop/start) + hermetic test"
```

---

### Task 2: Makefile-таргет `llama-cpp-restart` + graph-тест + `local.mk.example`

**Files:**
- Modify: `Makefile` (переменные после строки `LLAMA_URL = ...`; sysconfig-gen `lact-autoswitch`; новый таргет в конце файла)
- Modify: `scripts/test-makefile-graph.sh` (цикл секции 1; новая секция 24)
- Modify: `local.mk.example` (закомментированная строка `OPENCODE_CONFIG`)

**Interfaces:**
- Consumes: `scripts/llama-cpp-restart.sh` из Task 1 (argv/env-контракт).
- Produces: `make llama-cpp-restart [MODE=check|restart|stop|start] [IDLE_TIMEOUT=N] [READY_TIMEOUT=N] [VERIFY_REQUEST=TEXT] [RESTART_LOG=path]` — запускает скрипт через `setsid -f` в шелле toolbx, рецепт возвращается сразу. Task 3 (доки) описывает ровно этот интерфейс.

- [ ] **Step 1: Graph-тест — добавить `llama-cpp-restart` в цикл секции 1 (красный)**

В `scripts/test-makefile-graph.sh`, строки 236–238:

Было:
```sh
for t in nvidia-base kernel-devel kernel-redist kmod-oss kmod nvidia-redist-drv lact-redist \
         nvidia-xorg nvidia-cuda-devel nvidia-cuda-libs nvidia-nccl-devel \
          nvidia-nccl-libs nvidia-lact nvidia-lact-autoswitch nvidia-nccl llama-cpp-cuda llama-cpp-cuda-debug clean systemd ; do
```
Стало (добавить `llama-cpp-restart` в конец списка):
```sh
for t in nvidia-base kernel-devel kernel-redist kmod-oss kmod nvidia-redist-drv lact-redist \
         nvidia-xorg nvidia-cuda-devel nvidia-cuda-libs nvidia-nccl-devel \
          nvidia-nccl-libs nvidia-lact nvidia-lact-autoswitch nvidia-nccl llama-cpp-cuda llama-cpp-cuda-debug clean systemd llama-cpp-restart ; do
```

- [ ] **Step 2: Graph-тест — новая секция 24 (красный)**

В конец `scripts/test-makefile-graph.sh`, перед `echo "# pass=$pass fail=$fail"`:

```sh
# --- 24. llama-cpp-restart (recipe plumbing; setsid stubbed — скрипт не запускается) ---
mkdir -p "$tmp/setsid-stub"
cat > "$tmp/setsid-stub/setsid" <<'SH'
#!/bin/sh
echo "stub-setsid $*" >> "${FAKE_SETSID_LOG:?}"
exit 0
SH
chmod +x "$tmp/setsid-stub/setsid"
FAKE_SETSID_LOG="$tmp/setsid.log"
export FAKE_SETSID_LOG
: > "$FAKE_SETSID_LOG"

PATH="$tmp/setsid-stub:$PATH" make_target llama-cpp-restart MODE=check \
    HOST_ROOT="$tmp/hostroot" SYSTEMDCTL="$tmp/fake-systemctl" RESTART_LOG="$tmp/restart.log"
expect_make_rc "llama-cpp-restart rc=0" 0
for frag in \
    'stub-setsid -f env CRE=' \
    "HOST_ROOT=$tmp/hostroot" \
    "SYSTEMDCTL=$tmp/fake-systemctl" \
    'LLAMA_URL=http://127.0.0.1:8080' \
    'LLAMA_MODEL=default' \
    'LLAMA_KEYS_FILE=/etc/llama/llama-cpp-keys.txt' \
    'LLAMA_CONTAINER=llama-cpp' \
    'OPENCODE_CONFIG= ./scripts/llama-cpp-restart.sh check --idle-timeout 30 --ready-timeout 600' ; do
    if grep -qF -- "$frag" "$FAKE_SETSID_LOG"; then
        ok "llama-cpp-restart recipe: $frag"
    else
        ko "llama-cpp-restart recipe: $frag" "in stub-setsid log" "$(cat "$FAKE_SETSID_LOG")"
    fi
done
if printf '%s' "$make_out" | grep -qF "llama-cpp-restart: started (log=$tmp/restart.log"; then
    ok "llama-cpp-restart: started-echo"
else
    ko "llama-cpp-restart: started-echo" "echo with RESTART_LOG" "make out: $make_out"
fi

# fail-loud: no local.mk -> отказ до setsid
rm -f "$repo_root/local.mk"
: > "$FAKE_SETSID_LOG"
PATH="$tmp/setsid-stub:$PATH" make_target llama-cpp-restart MODE=check \
    HOST_ROOT="$tmp/hostroot" SYSTEMDCTL="$tmp/fake-systemctl" RESTART_LOG="$tmp/restart.log"
expect_make_rc "llama-cpp-restart fail-loud rc=2 (no local.mk)" 2
if printf '%s' "$make_out" | grep -qF -- "ERROR: no local.mk"; then
    ok "llama-cpp-restart fail-loud message"
else
    ko "llama-cpp-restart fail-loud message" "make output contains: ERROR: no local.mk" "make out: $make_out"
fi
if [ -s "$FAKE_SETSID_LOG" ]; then
    ko "llama-cpp-restart fail-loud: setsid not run" "empty stub log" "$(cat "$FAKE_SETSID_LOG")"
else
    ok "llama-cpp-restart fail-loud: setsid not run"
fi
printf 'LLAMA_HOST = 127.0.0.1\nLLM_NFS_SERVER = 127.0.0.1\n' > "$repo_root/local.mk"
```

Зависимости секции (уже определены в тесте выше по файлу): `$tmp/cre` (fake CRE), секция 19 создаёт `$tmp/hostroot`, `$tmp/fake-systemctl`; local.mk-стуб пишется секцией 19 (на момент секции 24 он на месте; восстановление — EXIT-trap).

- [ ] **Step 3: Запустить graph-тест — убедиться, что красный**

Run: `bash scripts/test-makefile-graph.sh`
Expected: FAIL — `make -n llama-cpp-restart` (нет таргета, rc≠0) и секция 24 красная.

- [ ] **Step 4: Makefile — переменные (после строки `LLAMA_URL = ...`)**

Было:
```make
LLAMA_HOST ?= 127.0.0.1
LLM_NFS_SERVER ?= 127.0.0.1
LLAMA_PORT ?= 8080
LLAMA_URL = http://$(LLAMA_HOST):$(LLAMA_PORT)
```
Стало:
```make
LLAMA_HOST ?= 127.0.0.1
LLM_NFS_SERVER ?= 127.0.0.1
LLAMA_PORT ?= 8080
LLAMA_URL = http://$(LLAMA_HOST):$(LLAMA_PORT)
LLAMA_MODEL ?= default
LLAMA_KEYS_FILE ?= /etc/llama/llama-cpp-keys.txt
OPENCODE_CONFIG ?=
```

- [ ] **Step 5: Makefile — sysconfig-gen `lact-autoswitch` на переменные**

В рецепте `systemd` (существующие строки):

Было:
```make
	  --default LLAMA_MODEL=default \
	  --default LLAMA_KEYS_FILE=/etc/llama/llama-cpp-keys.txt \
```
Стало:
```make
	  --default LLAMA_MODEL=$(LLAMA_MODEL) \
	  --default LLAMA_KEYS_FILE=$(LLAMA_KEYS_FILE) \
```
(Существующие syscfg-пины graph-теста ожидают расширенные значения `LLAMA_MODEL=default` / `LLAMA_KEYS_FILE=/etc/llama/llama-cpp-keys.txt` — после замены они остаются валидными.)

- [ ] **Step 6: Makefile — новый таргет в конец файла**

После последней строки файла (рецепт `systemd`, `$(SYSTEMDCTL) enable ...`):

```make
# Безопасный рестарт/стоп/старт живого llama-cpp-сервера (Этап 25).
# Скрипт исполняется в шелле toolbx через setsid -f (self-healing:
# переживает сессию); хост — через CRE/chroot, как в systemd-таргете.
# Протокол/состояния: LIVE-SERVER.md.
MODE ?= restart
IDLE_TIMEOUT ?= 30
READY_TIMEOUT ?= 600
VERIFY_REQUEST ?=
RESTART_LOG ?= /tmp/llm-rig/llama-cpp-restart.log

llama-cpp-restart:
	[ -f local.mk ] || { echo "ERROR: no local.mk (cp local.mk.example local.mk, fill in values)" >&2; exit 1; }
	mkdir -p $(dir $(RESTART_LOG))
	setsid -f env CRE=$(CRE) HOST_ROOT=$(HOST_ROOT) SYSTEMDCTL=$(SYSTEMDCTL) \
	  LLAMA_URL=$(LLAMA_URL) LLAMA_MODEL=$(LLAMA_MODEL) \
	  LLAMA_KEYS_FILE=$(LLAMA_KEYS_FILE) LLAMA_CONTAINER=$(LLAMA_CPP) \
	  OPENCODE_CONFIG=$(OPENCODE_CONFIG) \
	  ./scripts/llama-cpp-restart.sh $(MODE) --idle-timeout $(IDLE_TIMEOUT) \
	  --ready-timeout $(READY_TIMEOUT) $(if $(VERIFY_REQUEST),--verify-request $(VERIFY_REQUEST)) \
	  < /dev/null >> $(RESTART_LOG) 2>&1
	@echo "llama-cpp-restart: started (log=$(RESTART_LOG), status=/tmp/llm-rig/llama-cpp-restart.status)"
```

Формат: continuation — TAB + 2 пробела, команды — с одного TAB (пин 21a). `setsid -f` (always fork) — рецепт возвращается сразу.

- [ ] **Step 7: `local.mk.example` — закомментированная строка `OPENCODE_CONFIG`**

В конец `local.mk.example` (после блока CUDA-комментариев):

```make
# Opencode-конфиг сессии (опционал, Этап 25): нестандартный путь
# (например, в репо .opencode/). Без переменной скрипт llama-cpp-restart.sh
# ищет opencode.json{,c} в корне репо и в ~/.config/opencode/.
# OPENCODE_CONFIG = /path/to/opencode.jsonc
```

Без реальных значений (инвариант no-sensitive).

- [ ] **Step 8: Graph-тест зелёный**

Run: `bash scripts/test-makefile-graph.sh`
Expected: `# pass=N fail=0` (включая новые пины секции 24 и `make -n llama-cpp-restart` в цикле).

- [ ] **Step 9: Полный тест-сьют + no-sensitive**

Run: `for t in scripts/test-*.sh; do echo "== $t"; bash "$t" || break; done`
Expected: все `fail=0`; `test-no-sensitive` — pass (в `local.mk.example` только плейсхолдер `/path/to/...`, в tracked нет частных IP и значений local.mk).

- [ ] **Step 10: Commit**

```bash
git add Makefile scripts/test-makefile-graph.sh local.mk.example
git commit -m "feat: make llama-cpp-restart target (setsid -f plumbing) + graph pins; OPENCODE_CONFIG in local.mk.example"
```

---

### Task 3: `LIVE-SERVER.md` + секция/фикс в `AGENTS.md`

**Files:**
- Create: `LIVE-SERVER.md` (корень репо)
- Modify: `AGENTS.md` (фикс лог-строки в секции «Логи llama-server (llama-cpp)»; новая секция «Живой сервер (llama-cpp)» перед «Процесс: работа под superpowers (координатор)»)

**Interfaces:**
- Consumes: интерфейс `make llama-cpp-restart` (Task 2), протокол status/rc (Task 1).
- Produces: операционный референс для агентов (правило-триггер в AGENTS.md указывает сюда). Секция «Числа» заполняется live-окном (вне плана).

- [ ] **Step 1: Написать `LIVE-SERVER.md`**

```markdown
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
- **no** — сессия не на этом сервере; **unknown** (конфиг не найден) —
  консервативно: вести себя как yes.

## Рестарт / стоп / старт

    make llama-cpp-restart MODE=restart [IDLE_TIMEOUT=30] [READY_TIMEOUT=600] [VERIFY_REQUEST=...]
    make llama-cpp-restart MODE=check   # read-only: состояние + SAME_HOST
    make llama-cpp-restart MODE=stop    # wait-idle -> systemctl stop
    make llama-cpp-restart MODE=start   # systemctl start -> ready -> verify

- Self-healing: рецепт гоняет скрипт через `setsid -f` — он переживает
  сессию и таймаут tool-вызова, доводя сервер до готовности. Сессия
  может умереть в процессе рестарта — это по дизайну; координатор
  возвращается и опрашивает status.
- Поток restart: preflight (юнит active — иначе «осознанный
  стоп/обслуживание» и скрипт не трогает; ключи) → wait-idle (все
  слоты `is_processing=false`; таймаут → abort rc=3 **без форса** —
  known-issue stop/restart-hang при in-flight task) → `systemctl
  restart llama-cpp` → wait-ready (`/health` ok + `/v1/models`
  `loaded`) → verify (короткая генерация, `max_tokens=8`).
- rc: 0 ok; 2 preflight/usage/lock; 3 wait-idle (in-flight); 4
  systemctl; 5 wait-ready; 6 verify.
- Состояние: файл `/tmp/llm-rig/llama-cpp-restart.status` — строки
  `<ts> <state> <detail>` (часы toolbx — UTC); states: `start` (с pid),
  `preflight`, `same-host`, `wait-idle`, `restarting`, `wait-ready`,
  `verifying`; финальная строка `done rc=0` / `failed rc=<N> <reason>`.
  Лог — `/tmp/llm-rig/llama-cpp-restart.log`. Опрос координатором:
  повторное чтение файла между шагами, до финальной строки.

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

- t0→t1 даунтайм (старт рестарта → первый `/health` ok): —
- t1→t2 загрузка модели (→ `/v1/models` `loaded`): —
- t3 verify (200, tok/s): —
- Ре-префилл первого запроса сессии после рестарта (cache-ram пуст): —

## Логи

- `AGENTS.md`, секция «Логи llama-server (llama-cpp)» (таймстемпы
  `мм.сс.ммм.ммм`, префикс `[NNNNN]` = порт instance, нумерация task).
- Постоянная история: `journalctl -lu llama-cpp [--since ...]` (вывод
  сервера уходит в журнал юнита; watcher работает по нему).
- `podman-remote logs llama-cpp` — только текущий контейнер
  (`ExecStartPre` удаляет контейнер — история не накапливается).
```

- [ ] **Step 2: `AGENTS.md` — фикс лог-строки (секция «Логи llama-server (llama-cpp)»)**

Было:
```markdown
- `podman-remote logs llama-cpp` накапливается между рестартами
  контейнера; нумерация task в каждом новом instance начинается заново.
```
Стало:
```markdown
- `podman-remote logs llama-cpp` — только текущий контейнер (юнитовый
  `ExecStartPre` удаляет его); постоянная история — `journalctl -lu
  llama-cpp [--since ...]`. Нумерация task в каждом новом instance
  начинается заново.
```

- [ ] **Step 3: `AGENTS.md` — новая секция перед «Процесс: работа под superpowers (координатор)»**

```markdown
## Живой сервер (llama-cpp)

Перед первым действием над живым llama-cpp-сервером (рестарт/стоп/старт,
ключи, sysconfig, контейнер/юнит, прод-логи) — прочитать
`LIVE-SERVER.md`.

```

- [ ] **Step 4: Проверки — no-sensitive и полный сьют**

Run: `bash scripts/test-no-sensitive.sh`
Expected: `fail=0` (в `LIVE-SERVER.md` только `127.0.0.1`/`localhost` — не частные IP; ключей и значений local.mk нет).

Run: `for t in scripts/test-*.sh; do echo "== $t"; bash "$t" || break; done`
Expected: все `fail=0`.

- [ ] **Step 5: Commit**

```bash
git add LIVE-SERVER.md AGENTS.md
git commit -m "docs: LIVE-SERVER.md (live llama-cpp operations) + AGENTS.md trigger section and log-history fix"
```

---

## После плана (вне задач)

1. **Live-окно** (по спеке, секция «Live-окно»): pre-снимки → прогон 1
   `MODE=check` (SAME_HOST=yes) → прогон 2 in-flight abort (rc=3,
   сервер не тронут) → прогон 3 полный рестарт с таймлайном t0→t1→t2→t3
   (время — с длинами контекста) → приёмка: rc=0, verify 200, **сессия
   координатора продолжает работу после рестарта** → заполнить
   `LIVE-SERVER.md`, секция «Числа» (отдельным коммитом, доки) → отчёт
   `docs/superpowers/reports/2026-09-0X-stage25-safe-restart.md` →
   чекбоксы `TODO.md` → finishing-a-development-branch (merge в `main`).
2. **Критерии готовности** — по спеке, секция «Критерии готовности».
