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
KEY_CFG="$STATUS.keycfg"
rm -f "$KEY_CFG"
trap 'rm -f "$KEY_CFG"' EXIT

st() { # $1=state $2=detail; строка: <ts> <state> <detail>
    echo "$(date '+%FT%T') $1 $2" >> "$STATUS"
    echo "[$(date '+%FT%T')] $1 $2"
}
done_ok() { st done "rc=0"; exit 0; }
fail() { st failed "rc=$1 ${*:2}"; exit "$1"; }

# --- ключ: только из файла в рантайме; в логи/argv не попадает (curl — через 0600-конфиг) ---
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
    [ "${2:-0}" = 1 ] && a+=(-K "$KEY_CFG")
    HTTP_CODE=$(curl "${a[@]}") || HTTP_CODE=000
}
post_json() { # $1=path $2=json (keyed)
    HTTP_CODE=$(curl -sS -m 120 -o "$BODY_FILE" -w '%{http_code}' -X POST \
        -K "$KEY_CFG" -H 'Content-Type: application/json' \
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
    ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$KEY" > "$KEY_CFG" )
    chmod 600 "$KEY_CFG"
    st preflight "ok unit=$unit_state"
}

wait_idle() {
    st wait-idle "timeout=${IDLE_TIMEOUT}s model=$LLAMA_MODEL"
    local deadline=$(( $(date +%s) + IDLE_TIMEOUT ))
    local slots busy
    while :; do
        if slots=$(curl -sS -f -m 10 -K "$KEY_CFG" "$LLAMA_URL/slots?model=$LLAMA_MODEL" 2>/dev/null); then
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
        get /v1/models 1
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
    if ! slots=$(curl -sS -f -m 10 -K "$KEY_CFG" "$LLAMA_URL/slots?model=$LLAMA_MODEL" 2>/dev/null); then
        fail 2 "slots недоступны"
    fi
    busy=$(grep -o '"is_processing":true' <<< "$slots" | wc -l)
    st check "slots busy=$busy"
    get /v1/models 1
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
