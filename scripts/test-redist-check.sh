#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
server_pid=
trap '
    if [ -n "${server_pid:-}" ]; then kill "$server_pid" 2>/dev/null || true; fi
    "$repo_root/scripts/safe-rm" --under "$(dirname "$tmp")" "$tmp" 2>/dev/null || true
' EXIT INT TERM

port=18765
url="http://127.0.0.1:$port/driver.run"
no_etag_url="http://127.0.0.1:$port/no-etag"
printf 'test-driver-content\n' > "$tmp/driver.run"
printf 'test-driver-content\n' > "$tmp/no-etag"
size=$(wc -c < "$tmp/driver.run" | tr -d '[:space:]')
etag='"test-etag"'

cat > "$tmp/server.py" <<'PY'
import functools
import http.server
import sys

port = int(sys.argv[1])
directory = sys.argv[2]

class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        if not self.path.startswith("/no-etag"):
            self.send_header("ETag", '"test-etag"')
        super().end_headers()

    def log_message(self, *args):
        pass

http.server.ThreadingHTTPServer(
    ("127.0.0.1", port),
    functools.partial(Handler, directory=directory),
).serve_forever()
PY

python3 "$tmp/server.py" "$port" "$tmp" &
server_pid=$!

for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if curl -fsS "$url" > /dev/null 2>&1; then
        break
    fi
    sleep 0.1
done
curl -fsS "$url" > /dev/null

cat > "$tmp/cre" <<'SH'
#!/bin/sh
if [ "${1:-}" = "inspect" ]; then
    if [ "${FAKE_IMAGE_EXISTS:-0}" != "1" ]; then
        exit 1
    fi
    fmt=${3:-}
    case "$fmt" in
        *".url"*) printf '%s\n' "${FAKE_LABEL_URL:-}" ;;
        *".size"*) printf '%s\n' "${FAKE_LABEL_SIZE:-}" ;;
        *".etag"*) printf '%s\n' "${FAKE_LABEL_ETAG:-}" ;;
    esac
fi
exit 0
SH
chmod +x "$tmp/cre"

pass=0
fail=0

ok() {
    pass=$((pass + 1))
    echo "ok - $1"
}

ko() {
    fail=$((fail + 1))
    echo "not ok - $1"
    echo "  expected: $2"
    echo "  actual:   $3"
}

expect_up_to_date() {
    desc=$1
    out=$2
    rc=$3
    if [ "$rc" -eq 0 ] && [ "$out" = "up-to-date" ]; then
        ok "$desc"
    else
        ko "$desc" "rc=0 out=up-to-date" "rc=$rc out=$out"
    fi
}

expect_rebuild() {
    desc=$1
    out=$2
    rc=$3
    exp_size=$4
    exp_etag=$5
    set -- $out
    if [ "$rc" -eq 0 ] && [ "${1:-}" = "rebuild" ] && [ "${2:-}" = "$exp_size" ] && [ "${3:-}" = "$exp_etag" ]; then
        ok "$desc"
    else
        ko "$desc" "rc=0 out=rebuild $exp_size $exp_etag" "rc=$rc out=$out"
    fi
}

expect_rc() {
    desc=$1
    out=$2
    rc=$3
    exp_rc=$4
    if [ "$rc" -eq "$exp_rc" ]; then
        ok "$desc"
    else
        ko "$desc" "rc=$exp_rc" "rc=$rc out=$out"
    fi
}

run_helper() {
    rc=0
    helper_out=$(CRE="$tmp/cre" \
        FAKE_IMAGE_EXISTS=${FAKE_IMAGE_EXISTS:-0} \
        FAKE_LABEL_URL=${FAKE_LABEL_URL:-} \
        FAKE_LABEL_SIZE=${FAKE_LABEL_SIZE:-} \
        FAKE_LABEL_ETAG=${FAKE_LABEL_ETAG:-} \
        "$repo_root/scripts/redist-check.sh" "$@" 2>"$tmp/helper.err") || rc=$?
    helper_rc=$rc
}

FAKE_IMAGE_EXISTS=0
run_helper "$url" test-image com.nvidia/driver.redist
expect_rebuild "no image -> rebuild" "$helper_out" "$helper_rc" "$size" "$etag"

FAKE_IMAGE_EXISTS=1 FAKE_LABEL_URL="$url" FAKE_LABEL_SIZE="$size" FAKE_LABEL_ETAG="$etag"
run_helper "$url" test-image com.nvidia/driver.redist
expect_up_to_date "labels match -> up-to-date" "$helper_out" "$helper_rc"

FAKE_IMAGE_EXISTS=1 FAKE_LABEL_URL="$url" FAKE_LABEL_SIZE="wrong" FAKE_LABEL_ETAG="$etag"
run_helper "$url" test-image com.nvidia/driver.redist
expect_rebuild "size mismatch -> rebuild" "$helper_out" "$helper_rc" "$size" "$etag"

FAKE_IMAGE_EXISTS=1 FAKE_LABEL_URL="$url" FAKE_LABEL_SIZE="$size" FAKE_LABEL_ETAG="wrong"
run_helper "$url" test-image com.nvidia/driver.redist
expect_rebuild "etag mismatch -> rebuild" "$helper_out" "$helper_rc" "$size" "$etag"

FAKE_IMAGE_EXISTS=1 FAKE_LABEL_URL="wrong" FAKE_LABEL_SIZE="$size" FAKE_LABEL_ETAG="$etag"
run_helper "$url" test-image com.nvidia/driver.redist
expect_rebuild "url mismatch -> rebuild" "$helper_out" "$helper_rc" "$size" "$etag"

FAKE_IMAGE_EXISTS=1 FAKE_LABEL_URL="$url" FAKE_LABEL_SIZE="$size" FAKE_LABEL_ETAG="$etag"
run_helper --force "$url" test-image com.nvidia/driver.redist
expect_rebuild "--force -> rebuild" "$helper_out" "$helper_rc" "$size" "$etag"

FAKE_IMAGE_EXISTS=1
run_helper "http://127.0.0.1:1/unreachable" test-image com.nvidia/driver.redist
expect_rc "remote unreachable -> exit 2" "$helper_out" "$helper_rc" 2

FAKE_IMAGE_EXISTS=0
run_helper "$no_etag_url" test-image com.nvidia/driver.redist
expect_rebuild "missing etag -> rebuild with empty etag" "$helper_out" "$helper_rc" "$size" ""

FAKE_IMAGE_EXISTS=1 FAKE_LABEL_URL="$no_etag_url" FAKE_LABEL_SIZE="$size" FAKE_LABEL_ETAG=""
run_helper "$no_etag_url" test-image com.nvidia/driver.redist
expect_up_to_date "missing etag and empty label -> up-to-date" "$helper_out" "$helper_rc"

# --- CRE default: no-cre-hardcode, detection by /run/.containerenv ---
if grep -qF '/run/.containerenv' "$repo_root/scripts/redist-check.sh" && ! grep -qF ': "${CRE:=podman-remote}"' "$repo_root/scripts/redist-check.sh"; then
    ok "redist-check: CRE default via /run/.containerenv (no hardcode)"
else
    ko "redist-check: CRE default via /run/.containerenv (no hardcode)" "detection present, hardcoded default absent" "$(grep -n 'CRE' "$repo_root/scripts/redist-check.sh")"
fi

mkdir -p "$tmp/crebin"
printf '#!/bin/sh\necho "podman $*" >> "%s"\n' "$tmp/credefault.log" > "$tmp/crebin/podman"
printf '#!/bin/sh\necho "podman-remote $*" >> "%s"\n' "$tmp/credefault.log" > "$tmp/crebin/podman-remote"
chmod +x "$tmp/crebin/podman" "$tmp/crebin/podman-remote"
rm -f "$tmp/credefault.log"
cre_rc=0
cre_out=$(env -u CRE PATH="$tmp/crebin:$PATH" "$repo_root/scripts/redist-check.sh" --force "$url" test-image com.nvidia/driver.redist 2>&1) || cre_rc=$?
if [ -e /run/.containerenv ]; then exp_cre=podman-remote; else exp_cre=podman; fi
if grep -q "^$exp_cre inspect " "$tmp/credefault.log"; then
    ok "redist-check: CRE default = $exp_cre (shim log)"
else
    ko "redist-check: CRE default = $exp_cre (shim log)" "$exp_cre inspect ..." "$(cat "$tmp/credefault.log" 2>/dev/null || echo 'no log') rc=$cre_rc out=$cre_out"
fi

echo "# pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
