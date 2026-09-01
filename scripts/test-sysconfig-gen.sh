#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
gen="$repo_root/scripts/sysconfig-gen.sh"
pass=0
fail=0

trap '
    "$repo_root/scripts/safe-rm" --under "$(dirname "$tmp")" "$tmp" 2>/dev/null || true
' EXIT INT TERM

ok() { pass=$((pass + 1)); echo "ok - $1"; }
ko() { fail=$((fail + 1)); echo "not ok - $1"; echo "  expected: $2"; echo "  actual:   $3"; }

expect_content() { # desc file expected
    if [ "$(cat "$2" 2>/dev/null)" = "$3" ]; then
        ok "$1"
    else
        ko "$1" "$3" "$(cat "$2" 2>/dev/null)"
    fi
}

# --- 1. no file -> created with all keys, mode 0644 ---
d=$tmp/t1
mkdir -p "$d"
"$gen" "$d" nvidia-kmod --build KMOD_IMAGE=nvidia-kmod-610.43.03:test-kver
expect_content "t1 created content" "$d/nvidia-kmod" "KMOD_IMAGE=nvidia-kmod-610.43.03:test-kver"
if [ "$(stat -c %a "$d/nvidia-kmod")" = "644" ]; then
    ok "t1 mode 0644"
else
    ko "t1 mode 0644" "644" "$(stat -c %a "$d/nvidia-kmod")"
fi

# --- 2. operator values preserved, build values updated, positions kept ---
d=$tmp/t2
mkdir -p "$d"
cat > "$d/nvidia-card-setting" <<'EOF'
LACT_IMAGE=nvidia-lact-600.00.00:old-kver
PWR_LIMIT=120
MEM_CLOCK_OFFSET=900
EOF
"$gen" "$d" nvidia-card-setting \
    --build LACT_IMAGE=nvidia-lact-610.43.03:new-kver \
    --default PWR_LIMIT=140 \
    --default MEM_CLOCK_OFFSET=1000
expect_content "t2 merge" "$d/nvidia-card-setting" "LACT_IMAGE=nvidia-lact-610.43.03:new-kver
PWR_LIMIT=120
MEM_CLOCK_OFFSET=900"

# --- 3. unknown keys and comments preserved, missing default appended ---
d=$tmp/t3
mkdir -p "$d"
cat > "$d/llama-cpp" <<'EOF'
# operator comment
LLAMA_IMAGE=old-image:1
CUSTOM_KEY=keep-me
EOF
"$gen" "$d" llama-cpp --build LLAMA_IMAGE=new-image:2 --default LLAMA_PORT=8080
expect_content "t3 unknown/comment preserved" "$d/llama-cpp" "# operator comment
LLAMA_IMAGE=new-image:2
CUSTOM_KEY=keep-me
LLAMA_PORT=8080"

# --- 4. idempotency: second call does not change the file ---
d=$tmp/t4
mkdir -p "$d"
"$gen" "$d" llama-cpp \
    --build LLAMA_IMAGE=llama-cpp-cuda:13.2 \
    --default LLAMA_PORT=8080 \
    --default LLAMA_SHM_SIZE=64g
cp "$d/llama-cpp" "$d/llama-cpp.snap"
"$gen" "$d" llama-cpp \
    --build LLAMA_IMAGE=llama-cpp-cuda:13.2 \
    --default LLAMA_PORT=8080 \
    --default LLAMA_SHM_SIZE=64g
if cmp -s "$d/llama-cpp" "$d/llama-cpp.snap"; then
    ok "t4 idempotent"
else
    ko "t4 idempotent" "file unchanged" "$(diff "$d/llama-cpp.snap" "$d/llama-cpp" || true)"
fi

# --- 5. value with spaces (FAN_CURVE) — one argv, one line; empty value ---
d=$tmp/t5
mkdir -p "$d"
"$gen" "$d" nvidia-card-setting \
    --build LACT_IMAGE=nvidia-lact-610.43.03:v0.10.0 \
    --default "FAN_CURVE=45:0.30 65:0.40 70:0.65 75:0.80" \
    --default PER_CARD_OVERRIDES=
if [ "$(grep -c '^FAN_CURVE=' "$d/nvidia-card-setting")" = "1" ] && \
   grep -qx 'FAN_CURVE=45:0.30 65:0.40 70:0.65 75:0.80' "$d/nvidia-card-setting" && \
   grep -qx 'PER_CARD_OVERRIDES=' "$d/nvidia-card-setting"; then
    ok "t5 FAN_CURVE single value + empty PER_CARD_OVERRIDES"
else
    ko "t5 FAN_CURVE single value" "one exact line + empty line" "$(cat "$d/nvidia-card-setting")"
fi

# --- 6. usage errors (rc=2) ---
if "$gen" 2>/dev/null; then
    ko "t6 usage: no args rc=2" "rc=2" "rc=0"
else
    rc=$?
    if [ "$rc" = "2" ]; then ok "t6 usage: no args rc=2"; else ko "t6 usage: no args rc=2" "rc=2" "rc=$rc"; fi
fi
if "$gen" "$tmp" "bad/name" --build A=1 2>/dev/null; then
    ko "t6 usage: bad name rc=2" "rc=2" "rc=0"
else
    rc=$?
    if [ "$rc" = "2" ]; then ok "t6 usage: bad name rc=2"; else ko "t6 usage: bad name rc=2" "rc=2" "rc=$rc"; fi
fi
if "$gen" "$tmp" ok-name --default A=1 2>/dev/null; then
    ko "t6 usage: no --build rc=2" "rc=2" "rc=0"
else
    rc=$?
    if [ "$rc" = "2" ]; then ok "t6 usage: no --build rc=2"; else ko "t6 usage: no --build rc=2" "rc=2" "rc=$rc"; fi
fi
if "$gen" "$tmp" ok-name --build NOEQUALS 2>/dev/null; then
    ko "t6 usage: K=v without = rc=2" "rc=2" "rc=0"
else
    rc=$?
    if [ "$rc" = "2" ]; then ok "t6 usage: K=v without = rc=2"; else ko "t6 usage: K=v without = rc=2" "rc=2" "rc=$rc"; fi
fi
if "$gen" "$tmp/nonexistent-dir" ok-name --build A=1 2>/dev/null; then
    ko "t6 missing dir rc=1" "rc=1" "rc=0"
else
    rc=$?
    if [ "$rc" = "1" ]; then ok "t6 missing dir rc=1"; else ko "t6 missing dir rc=1" "rc=1" "rc=$rc"; fi
fi

echo "# pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
