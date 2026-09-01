#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
server_pid=
trap '
    if [ -n "${server_pid:-}" ]; then kill "$server_pid" 2>/dev/null || true; fi
    "$repo_root/scripts/safe-rm" --under "$(dirname "$tmp")" "$tmp" 2>/dev/null || true
' EXIT INT TERM

port=18766
url="http://127.0.0.1:$port/driver.run"
printf 'test-makefile-content\n' > "$tmp/driver.run"
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
state=${FAKE_STATE:?}
log=${FAKE_LOG:?}
case "${1:-}" in
    inspect)
        [ -f "$state" ] || exit 1
        fmt=${3:-}
        case "$fmt" in
            *".url"*) sed -n 's/^url=//p' "$state" ;;
            *".size"*) sed -n 's/^size=//p' "$state" ;;
            *".etag"*) sed -n 's/^etag=//p' "$state" ;;
        esac
        ;;
    image)
        if [ -f "$state" ]; then
            exit 0
        fi
        exit 1
        ;;
    build)
        echo "build $*" >> "$log"
        url=
        size=
        etag=
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --build-arg)
                    shift
                    case "${1:-}" in
                        DRIVER_URL=*|CUDA_URL=*) url=${1#*=} ;;
                        REDIST_SIZE=*) size=${1#*=} ;;
                        REDIST_ETAG=*) etag=${1#*=} ;;
                    esac
                    ;;
            esac
            shift
        done
        printf 'url=%s\nsize=%s\netag=%s\n' "$url" "$size" "$etag" > "$state"
        ;;
esac
exit 0
SH
chmod +x "$tmp/cre"

export FAKE_STATE=$tmp/state
export FAKE_LOG=$tmp/build.log
rm -f "$FAKE_STATE" "$FAKE_LOG"

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

make_target() {
    target=$1
    shift
    rc=0
    make_out=$(make -C "$repo_root" -s "$target" CRE="$tmp/cre" "$@" 2>&1) || rc=$?
    make_rc=$rc
}

expect_make_rc() {
    desc=$1
    exp_rc=$2
    if [ "$make_rc" -eq "$exp_rc" ]; then
        ok "$desc"
    else
        ko "$desc" "make rc=$exp_rc" "make rc=$make_rc out=$make_out"
    fi
}

expect_make_failed() {
    desc=$1
    if [ "$make_rc" -ne 0 ]; then
        ok "$desc"
    else
        ko "$desc" "make rc!=0" "make rc=$make_rc out=$make_out"
    fi
}

expect_output_contains() {
    desc=$1
    pattern=$2
    if printf '%s\n' "$make_out" | grep -qF -- "$pattern"; then
        ok "$desc"
    else
        ko "$desc" "output contains $pattern" "output=$make_out"
    fi
}

expect_log_lines() {
    desc=$1
    expected=$2
    actual=$(wc -l < "$FAKE_LOG" | tr -d '[:space:]')
    if [ "$actual" = "$expected" ]; then
        ok "$desc"
    else
        ko "$desc" "build log lines=$expected" "build log lines=$actual"
    fi
}

expect_log_contains() {
    desc=$1
    pattern=$2
    if grep -qF -- "$pattern" "$FAKE_LOG"; then
        ok "$desc"
    else
        ko "$desc" "build log contains $pattern" "build log=$(cat "$FAKE_LOG")"
    fi
}

make_target nvidia-redist-drv NVIDIA_DRV_VER=test NVIDIA_DRV_RUN_URL="$url"
expect_make_rc "driver no image -> build" 0
expect_log_lines "driver build recorded once" 1
expect_log_contains "driver build uses DRIVER_URL" "--build-arg DRIVER_URL=$url"
expect_log_contains "driver build uses REDIST_SIZE" "--build-arg REDIST_SIZE=$size"
expect_log_contains "driver build uses REDIST_ETAG" "--build-arg REDIST_ETAG=$etag"
expect_log_contains "driver tags test image" "-t nvidia-redist-drv:test"

make_target nvidia-redist-drv NVIDIA_DRV_VER=test NVIDIA_DRV_RUN_URL="$url"
expect_make_rc "driver labels match -> up-to-date" 0
expect_output_contains "driver prints up to date" "nvidia-redist-drv:test up to date"
expect_log_lines "driver second run does not build" 1

printf 'url=%s\nsize=wrong\netag=%s\n' "$url" "$etag" > "$FAKE_STATE"
make_target nvidia-redist-drv NVIDIA_DRV_VER=test NVIDIA_DRV_RUN_URL="$url"
expect_make_rc "driver label mismatch -> rebuild" 0
expect_log_lines "driver mismatch build recorded" 2

make_target nvidia-redist-drv FORCE=1 NVIDIA_DRV_VER=test NVIDIA_DRV_RUN_URL="$url"
expect_make_rc "driver FORCE -> rebuild" 0
expect_log_lines "driver FORCE build recorded" 3

make_target nvidia-redist-drv NVIDIA_DRV_VER=test NVIDIA_DRV_RUN_URL="http://127.0.0.1:1/unreachable"
expect_make_rc "offline with image -> warn and succeed" 0
expect_output_contains "offline warning" "WARN: remote unreachable, using existing nvidia-redist-drv:test"
expect_log_lines "offline with image does not build" 3

rm -f "$FAKE_STATE"
make_target nvidia-redist-drv NVIDIA_DRV_VER=test NVIDIA_DRV_RUN_URL="http://127.0.0.1:1/unreachable"
expect_make_failed "offline no image -> error"
expect_output_contains "offline no image error" "ERROR: remote unreachable"
expect_log_lines "offline no image does not build" 3

make_target nvidia-redist-drv FORCE=1 NVIDIA_DRV_VER=test NVIDIA_DRV_RUN_URL="http://127.0.0.1:1/unreachable"
expect_make_failed "offline FORCE -> error"
expect_log_lines "offline FORCE does not build" 3

rm -f "$FAKE_STATE" "$FAKE_LOG"
make_target nvidia-redist-cuda NVIDIA_CUDA_VER=test NVIDIA_CUDA_URL="$url"
expect_make_rc "cuda no image -> build" 0
expect_log_lines "cuda build recorded once" 1
expect_log_contains "cuda build uses CUDA_URL" "--build-arg CUDA_URL=$url"
expect_log_contains "cuda build uses REDIST_SIZE" "--build-arg REDIST_SIZE=$size"
expect_log_contains "cuda build uses REDIST_ETAG" "--build-arg REDIST_ETAG=$etag"
expect_log_contains "cuda tags test image" "-t nvidia-redist-cuda:test"

make_target nvidia-redist-cuda NVIDIA_CUDA_VER=test NVIDIA_CUDA_URL="$url"
expect_make_rc "cuda labels match -> up-to-date" 0
expect_output_contains "cuda prints up to date" "nvidia-redist-cuda:test up to date"
expect_log_lines "cuda second run does not build" 1

echo "# pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
