#!/bin/sh
# test-kmod-select.sh — stage-18 KMOD_IMAGE auto-select: structural pins
# (grep -F, fixed lines) + functional tests (the real script against a PATH
# shim of the CRE tool). The shim is named by the CRE the test itself
# resolves with the Makefile:8 detection logic (no-cre-hardcode): toolbx —
# podman-remote, host — podman; the shim logs calls and answers
# `image exists` from a file of "existing images". Offline, no containers,
# no network. Harness: pattern of scripts/test-llama-cpp-watcher.sh.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
script=$repo_root/scripts/nvidia-kmod-select.sh
unit=$repo_root/resources/driver/nvidia-kmod.service
makefile=$repo_root/Makefile
tmp=$(mktemp -d)
pass=0
fail=0
trap '
    "$repo_root/scripts/safe-rm" --under "$(dirname "$tmp")" "$tmp" 2>/dev/null || true
' EXIT INT TERM

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

# desc, file, fixed-string, expected line count
check_count() {
    desc=$1; file=$2; needle=$3; want=$4
    if [ ! -f "$file" ]; then
        ko "$desc" "$needle x$want in $(basename "$file")" "file absent"
        return 0
    fi
    got=$(grep -cF -- "$needle" "$file" || true)
    if [ "$got" -eq "$want" ]; then
        ok "$desc"
    else
        ko "$desc" "$needle x$want" "x$got"
    fi
}

# --- 1. structural pins: the select script ---
check_count "sysconfig path (test override)" "$script" 'FILE=${KMOD_SYSCONFIG_FILE:-/etc/sysconfig/nvidia-kmod}' 1
check_count "CRE detection" "$script" '[ -e /run/.containerenv ]' 1
check_count "CRE remote branch" "$script" 'CRE=podman-remote' 1
check_count "image check" "$script" '"$CRE" image exists "$want"' 1
check_count "kernel source" "$script" 'kver=$(uname -r)' 1
check_count "atomic write: tmp" "$script" 'mktemp "${FILE}.XXXXXX"' 1
check_count "atomic write: mv" "$script" 'mv "$tmp" "$FILE"' 1
check_count "actionable error: build" "$script" 'make kmod KVER=' 1
check_count "actionable error: restart" "$script" 'systemctl restart nvidia-kmod' 1

# --- 2. structural pins: the unit ---
check_count "unit: ExecStartPre select script" "$unit" 'ExecStartPre=/usr/local/bin/nvidia-kmod-select.sh' 1
check_count "unit: commented line replaced" "$unit" '#ExecStartPre' 0

# --- 3. structural pins: the Makefile (target systemd) ---
check_count "makefile: cp script" "$makefile" 'cp scripts/nvidia-kmod-select.sh $(HOST_ROOT)/usr/local/bin/' 1
check_count "makefile: chmod script" "$makefile" 'chmod 0755 $(HOST_ROOT)/usr/local/bin/nvidia-kmod-select.sh' 1

# --- 4. functional: the real script against a CRE shim ---
# CRE name — the test's own Makefile:8 detection (no-cre-hardcode):
# toolbx — podman-remote, host — podman.
CRE=podman
[ -e /run/.containerenv ] && CRE=podman-remote

shim_bin=$tmp/bin
mkdir -p "$shim_bin"
cre_log=$tmp/cre.log
images_file=$tmp/images
: > "$images_file"

cat > "$shim_bin/$CRE" <<SH
#!/bin/sh
echo "\$*" >> "$cre_log"
if [ "\$1" = "image" ] && [ "\$2" = "exists" ]; then
    grep -qxF -- "\$3" "\${IMAGES_FILE:?}"
else
    echo "unexpected $CRE args: \$*" >&2
    exit 1
fi
SH
chmod +x "$shim_bin/$CRE"

kver=$(uname -r)

# The real script against the shim; rc captured (fail paths are tested).
run_select() {
    rc=0
    env KMOD_SYSCONFIG_FILE="$tmp/sysconfig" IMAGES_FILE="$images_file" \
        PATH="$shim_bin:$PATH" bash "$script" >"$tmp/select.out" 2>&1 || rc=$?
}

# desc, expected-content-file: sysconfig byte-compare
expect_file() {
    if cmp -s "$2" "$tmp/sysconfig"; then
        ok "$1"
    else
        ko "$1" "$(cat "$2" 2>/dev/null)" "$(cat "$tmp/sysconfig" 2>/dev/null)"
    fi
}

# 4.1 tag rewrite + name (DRV prefix) from the file
printf '%s\n' 'KMOD_IMAGE=nvidia-kmod-999.99.99:7.1.4-200.fc44.x86_64' > "$tmp/sysconfig"
printf '%s\n' "nvidia-kmod-999.99.99:$kver" > "$images_file"
: > "$cre_log"
run_select
if [ "$rc" -eq 0 ]; then
    ok "rewrite: rc=0"
else
    ko "rewrite: rc=0" "rc=0" "rc=$rc; $(cat "$tmp/select.out")"
fi
printf '%s\n' "KMOD_IMAGE=nvidia-kmod-999.99.99:$kver" > "$tmp/expect"
expect_file "rewrite: tag re-pinned, prefix from file" "$tmp/expect"
if grep -qF -- "image exists nvidia-kmod-999.99.99:$kver" "$cre_log"; then
    ok "rewrite: image exists called with <name>:<uname -r>"
else
    ko "rewrite: image exists called with <name>:<uname -r>" "image exists nvidia-kmod-999.99.99:$kver in cre log" "$(cat "$cre_log")"
fi

# 4.2 idempotent no-op: file already at <kver>
printf '%s\n' "KMOD_IMAGE=nvidia-kmod-999.99.99:$kver" > "$tmp/sysconfig"
cp "$tmp/sysconfig" "$tmp/sysconfig.orig"
: > "$cre_log"
run_select
if [ "$rc" -eq 0 ]; then
    ok "no-op: rc=0"
else
    ko "no-op: rc=0" "rc=0" "rc=$rc; $(cat "$tmp/select.out")"
fi
expect_file "no-op: file untouched" "$tmp/sysconfig.orig"
calls=$(wc -l < "$cre_log")
if [ "$calls" -eq 1 ] && grep -qF -- "image exists nvidia-kmod-999.99.99:$kver" "$cre_log"; then
    ok "no-op: shim called once (image exists)"
else
    ko "no-op: shim called once (image exists)" "1 call" "$calls calls: $(cat "$cre_log")"
fi

# 4.3 absence: no image for the current kernel
printf '%s\n' 'KMOD_IMAGE=nvidia-kmod-999.99.99:7.1.4-200.fc44.x86_64' > "$tmp/sysconfig"
cp "$tmp/sysconfig" "$tmp/sysconfig.orig"
: > "$images_file"
: > "$cre_log"
run_select
if [ "$rc" -ne 0 ]; then
    ok "absence: rc!=0"
else
    ko "absence: rc!=0" "rc!=0" "rc=0"
fi
if grep -qF -- "make kmod KVER=$kver" "$tmp/select.out"; then
    ok "absence: actionable build command in stderr"
else
    ko "absence: actionable build command in stderr" "make kmod KVER=$kver" "$(cat "$tmp/select.out")"
fi
expect_file "absence: file untouched" "$tmp/sysconfig.orig"

# 4.4 no file
rm -f "$tmp/sysconfig"
run_select
if [ "$rc" -ne 0 ]; then
    ok "no file: rc!=0"
else
    ko "no file: rc!=0" "rc!=0" "rc=0"
fi
if grep -qF -- "make systemd" "$tmp/select.out"; then
    ok "no file: make systemd hint in stderr"
else
    ko "no file: make systemd hint in stderr" "make systemd" "$(cat "$tmp/select.out")"
fi

# 4.5 no KMOD_IMAGE key (file with other content)
printf '%s\n' 'OTHER_KEY=keep' > "$tmp/sysconfig"
run_select
if [ "$rc" -ne 0 ]; then
    ok "no key: rc!=0"
else
    ko "no key: rc!=0" "rc!=0" "rc=0"
fi
if grep -qF -- "no KMOD_IMAGE" "$tmp/select.out"; then
    ok "no key: 'no KMOD_IMAGE' in stderr"
else
    ko "no key: 'no KMOD_IMAGE' in stderr" "no KMOD_IMAGE" "$(cat "$tmp/select.out")"
fi

# 4.6 content preservation: comment + other key survive the rewrite,
#     line order kept
printf '%s\n' \
    '# nvidia-kmod sysconfig' \
    'OTHER_KEY=keep' \
    'KMOD_IMAGE=nvidia-kmod-999.99.99:7.1.4-200.fc44.x86_64' > "$tmp/sysconfig"
printf '%s\n' "nvidia-kmod-999.99.99:$kver" > "$images_file"
: > "$cre_log"
run_select
printf '%s\n' \
    '# nvidia-kmod sysconfig' \
    'OTHER_KEY=keep' \
    "KMOD_IMAGE=nvidia-kmod-999.99.99:$kver" > "$tmp/expect"
expect_file "content: comment + OTHER_KEY preserved, order kept" "$tmp/expect"

# 4.7 value without a tag
printf '%s\n' 'KMOD_IMAGE=nvidia-kmod-999.99.99' > "$tmp/sysconfig"
printf '%s\n' "nvidia-kmod-999.99.99:$kver" > "$images_file"
: > "$cre_log"
run_select
if [ "$rc" -eq 0 ]; then
    ok "untagged: rc=0"
else
    ko "untagged: rc=0" "rc=0" "rc=$rc; $(cat "$tmp/select.out")"
fi
printf '%s\n' "KMOD_IMAGE=nvidia-kmod-999.99.99:$kver" > "$tmp/expect"
expect_file "untagged: tag appended" "$tmp/expect"

echo "# pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
