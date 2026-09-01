#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
safe_rm=$repo_root/scripts/safe-rm
tmp=$(mktemp -d)
tmp2=$(mktemp -d)
pass=0
fail=0
trap '
    "$safe_rm" --under "$(dirname "$tmp")" "$tmp" 2>/dev/null || true
    "$safe_rm" --under "$(dirname "$tmp2")" "$tmp2" 2>/dev/null || true
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

# fake rm: records calls instead of removing; refusal tests run with it
# on PATH so a buggy guard can never invoke the real rm
shim_bin=$tmp/bin
mkdir -p "$shim_bin"
cat > "$shim_bin/rm" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "${FAKE_RM_LOG:?}"
exit 0
SH
chmod +x "$shim_bin/rm"
FAKE_RM_LOG=$tmp/rm.log
export FAKE_RM_LOG
shim_cleared() {
    rm -f "$FAKE_RM_LOG"
}

err_log=$tmp/err.log

# desc, stderr-pattern, command... ; expects rc != 0 and pattern in stderr
expect_fail() {
    desc=$1
    pattern=$2
    shift 2
    rc=0
    "$@" 2> "$err_log" || rc=$?
    if [ "$rc" -ne 0 ] && grep -qF -- "$pattern" "$err_log"; then
        ok "$desc"
    else
        ko "$desc" "rc!=0 and stderr~'$pattern'" "rc=$rc stderr=$(cat "$err_log")"
    fi
}

# desc, command... ; expects rc == 0
expect_ok() {
    desc=$1
    shift
    rc=0
    "$@" 2> "$err_log" || rc=$?
    if [ "$rc" -eq 0 ]; then
        ok "$desc"
    else
        ko "$desc" "rc=0" "rc=$rc stderr=$(cat "$err_log")"
    fi
}

expect_no_shim_call() {
    desc=$1
    if [ -f "$FAKE_RM_LOG" ]; then
        ko "$desc" "rm not invoked" "rm invoked: $(cat "$FAKE_RM_LOG")"
    else
        ok "$desc"
    fi
}

# --- 1. usage ---
expect_fail "usage: no args" "usage" "$safe_rm"
expect_fail "usage: no targets" "usage" "$safe_rm" --under "$tmp"
expect_fail "L0: relative root" "root must be an absolute path: tmp" "$safe_rm" --under tmp "$tmp/a"
expect_fail "L0: relative target" "target must be an absolute path: a" "$safe_rm" --under "$tmp" a
expect_fail "root does not exist" "root does not exist" "$safe_rm" --under "$tmp/no-such-root" "$tmp/a"

# --- 2. allow: real removal under root (no shim) ---
mkdir -p "$tmp/a/sub"
printf 'x\n' > "$tmp/a/sub/f"
expect_ok "allow: removes dir under root" "$safe_rm" --under "$tmp" "$tmp/a"
if [ ! -e "$tmp/a" ]; then
    ok "allow: dir actually gone"
else
    ko "allow: dir actually gone" "absent" "present"
fi

mkdir -p "$tmp/m1" "$tmp/m2"
expect_ok "allow: multiple targets" "$safe_rm" --under "$tmp" "$tmp/m1" "$tmp/m2"
if [ ! -e "$tmp/m1" ] && [ ! -e "$tmp/m2" ]; then
    ok "allow: both dirs gone"
else
    ko "allow: both dirs gone" "absent" "m1=$([ -e "$tmp/m1" ] && echo present || echo absent) m2=$([ -e "$tmp/m2" ] && echo present || echo absent)"
fi

expect_ok "allow: nonexistent target is no-op" "$safe_rm" --under "$tmp" "$tmp/never-existed"

mkdir -p "$tmp/self/sub"
expect_ok "allow: target equals root" "$safe_rm" --under "$tmp/self" "$tmp/self"
if [ ! -e "$tmp/self" ]; then
    ok "allow: root itself gone"
else
    ko "allow: root itself gone" "absent" "present"
fi

# --- 3. refuse: mount point (shim on PATH) ---
shim_cleared
expect_fail "L1: /proc is a mount point" "mount point" env PATH="$shim_bin:$PATH" "$safe_rm" --under /proc /proc
expect_no_shim_call "L1: /proc — rm not invoked"

shim_cleared
expect_fail "L1: trailing slash on mount point" "mount point" env PATH="$shim_bin:$PATH" "$safe_rm" --under /proc /proc/
expect_no_shim_call "L1: trailing slash — rm not invoked"

ln -s /proc "$tmp/link-proc"
shim_cleared
expect_fail "L1: symlink to mount point" "mount point" env PATH="$shim_bin:$PATH" "$safe_rm" --under "$tmp" "$tmp/link-proc"
expect_no_shim_call "L1: symlink — rm not invoked"

if [ -d /run/host ]; then
    shim_cleared
    expect_fail "L1: /run/host (host mount, toolbx)" "mount point" env PATH="$shim_bin:$PATH" "$safe_rm" --under /run/host /run/host
    expect_no_shim_call "L1: /run/host — rm not invoked"
fi

# --- 4. refuse: outside root (shim on PATH) ---
mkdir -p "$tmp2/outside"
shim_cleared
expect_fail "L2: target outside root" "outside root" env PATH="$shim_bin:$PATH" "$safe_rm" --under "$tmp" "$tmp2/outside"
expect_no_shim_call "L2: outside — rm not invoked"
if [ -e "$tmp2/outside" ]; then
    ok "L2: outside target intact"
else
    ko "L2: outside target intact" "present" "absent"
fi

mkdir -p "$tmp/good"
shim_cleared
expect_fail "all-or-nothing: one good + one bad target" "outside root" env PATH="$shim_bin:$PATH" "$safe_rm" --under "$tmp" "$tmp/good" "$tmp2/outside"
expect_no_shim_call "all-or-nothing — rm not invoked"
if [ -e "$tmp/good" ]; then
    ok "all-or-nothing: good target intact"
else
    ko "all-or-nothing: good target intact" "present" "absent"
fi

ln -s "$tmp2" "$tmp/link-escape"
shim_cleared
expect_fail "L2: symlink escaping root" "outside root" env PATH="$shim_bin:$PATH" "$safe_rm" --under "$tmp" "$tmp/link-escape"
expect_no_shim_call "L2: escape — rm not invoked"

echo "# pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
