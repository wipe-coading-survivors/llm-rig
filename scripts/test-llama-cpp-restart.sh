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
            # образ a01ce9ffc: публичен только /health; /v1/models — ключ
            if self.headers.get("Authorization", "") != "Bearer test-key-123":
                self._send(401, {"error": "unauthorized"})
                return
            if flag("ready"):
                self._send(200, {"data": [{"id": "default",
                                           "aliases": [],
                                           "status": {"value": "loaded"}}]})
            else:
                self._send(200, {"data": []})
        elif self.path.startswith("/slots"):
            if self.headers.get("Authorization", "") != "Bearer test-key-123":
                self._send(401, {"error": "unauthorized"})
                return
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
# любой HTTP-ответ = слушает (/v1/models теперь keyed; -f не ставим)
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if curl -sS -o /dev/null "http://127.0.0.1:$port/health" 2>/dev/null; then break; fi
    sleep 0.1
done
curl -sS -o /dev/null "http://127.0.0.1:$port/health"

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
KEYS_FILE="$tmp/keys.txt"
run_script() { # args to the script; log -> $tmp/run.log, status -> $tmp/run.status
    env CRE=podman HOST_ROOT= SYSTEMDCTL=systemctl \
        LLAMA_URL="http://127.0.0.1:$port" LLAMA_MODEL=default \
        LLAMA_KEYS_FILE="$KEYS_FILE" LLAMA_CONTAINER=llama-cpp \
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
run_script restart --idle-timeout 20 --ready-timeout 15 || rc=$?
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
if grep -qF -- '-H "Authorization: Bearer' "$script"; then
    ko "key not on curl argv in source" "no -H Bearer header in $script" \
        "$(grep -nF -- '-H \"Authorization: Bearer' "$script")"
else
    ok "key not on curl argv in source"
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

# --- 10. restart: wrong key (mock /slots 401) -> rc=3, no restart, server untouched ---
printf 'bad-key-999\n' > "$tmp/bad-keys.txt"
rm -f "$state/systemctl-calls"
ready_before=0
[ -f "$state/ready" ] && ready_before=1
KEYS_FILE="$tmp/bad-keys.txt"
rc=0
run_script restart --idle-timeout 2 || rc=$?
KEYS_FILE="$tmp/keys.txt"
if [ "$rc" -eq 3 ]; then
    ok "restart bad-key rc=3"
else
    ko "restart bad-key rc=3" "rc=3" "rc=$rc log: $(cat "$tmp/run.log")"
fi
if grep -qF ' failed rc=3 ' "$tmp/run.status"; then
    ok "restart bad-key status failed rc=3"
else
    ko "restart bad-key status failed rc=3" "line in status" "$(cat "$tmp/run.status")"
fi
if [ -e "$state/systemctl-calls" ] && grep -qx 'systemctl restart llama-cpp' "$state/systemctl-calls"; then
    ko "restart bad-key: no systemctl restart" "no 'systemctl restart llama-cpp' call" "$(cat "$state/systemctl-calls")"
else
    ok "restart bad-key: no systemctl restart"
fi
ready_after=0
[ -f "$state/ready" ] && ready_after=1
if [ "$ready_before" = "$ready_after" ]; then
    ok "restart bad-key: server untouched (ready flag as before)"
else
    ko "restart bad-key: server untouched (ready flag as before)" "ready=$ready_before" "ready=$ready_after"
fi

# --- 11. /v1/models keyed in script (image a01ce9ffc: public = /health only) ---
keyed_models=$(grep -cF 'get /v1/models 1' "$script" || true)
if [ "$keyed_models" -eq 2 ]; then
    ok "script: /v1/models keyed (wait_ready + check_mode)"
else
    ko "script: /v1/models keyed (wait_ready + check_mode)" "2 occurrences" "$keyed_models"
fi

echo "# pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
