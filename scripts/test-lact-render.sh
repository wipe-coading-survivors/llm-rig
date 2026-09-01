#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lact_sh="$repo_root/resources/driver/lact/lact.sh"

if [ ! -f "$lact_sh" ]; then
    echo "not ok - lact.sh exists"
    exit 1
fi

tmp=$(mktemp -d)
trap '"$repo_root/scripts/safe-rm" --under "$(dirname "$tmp")" "$tmp" 2>/dev/null || true' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok - $1"; }
ko() { fail=$((fail + 1)); echo "not ok - $1"; echo "  expected: $2"; echo "  actual:   $3"; }

ID_A="10DE:2487-10DE:2487-0000:03:00.0"
ID_B="10DE:2504-10DE:2504-0000:04:00.0"
PSTATES="0 2 3 5 8"

render() {
    bash "$lact_sh" render "$PSTATES" "$ID_A $ID_B" 2>/dev/null
}

# section extractors (4-block topology: top-level Default = gpus:,
# profiles: safe/idle/locked); per-section absence checks
sec_default() {
    printf '%s\n' "$out" | awk '/^gpus:$/ {f=1; next} /^profiles:$/ {f=0} f'
}
sec_profile() {
    printf '%s\n' "$out" | awk -v n="  $1:" '$0 == n {f=1; next} f && /^  [A-Za-z_]+:$/ {f=0} f'
}
sec_safe() { sec_profile safe; }
sec_idle() { sec_profile idle; }
sec_locked() { sec_profile locked; }

expect_count() {
    desc=$1
    pattern=$2
    want=$3
    got=$(printf '%s\n' "$out" | grep -cF -- "$pattern" || true)
    if [ "$got" = "$want" ]; then
        ok "$desc"
    else
        ko "$desc" "count of '$pattern' = $want" "count = $got"
    fi
}

expect_count_re() {
    desc=$1
    pattern=$2
    want=$3
    got=$(printf '%s\n' "$out" | grep -c -- "$pattern" || true)
    if [ "$got" = "$want" ]; then
        ok "$desc"
    else
        ko "$desc" "count of '$pattern' = $want" "count = $got"
    fi
}

expect_sec_count() { # desc secfunc fixed-pattern want
    desc=$1
    secfunc=$2
    pattern=$3
    want=$4
    got=$("$secfunc" | grep -cF -- "$pattern" || true)
    if [ "$got" = "$want" ]; then
        ok "$desc"
    else
        ko "$desc" "count of '$pattern' in $secfunc = $want" "count = $got"
    fi
}

out=$(render) || { echo "not ok - render exit 0"; exit 1; }

expect_count "version 6" "version: 6" 1
expect_count "daemon block" "daemon:" 1
expect_count "daemon log_level" "  log_level: info" 1
expect_count "daemon cleanup off" "  disable_clocks_cleanup: false" 1
expect_count "apply_settings_timer" "apply_settings_timer: 5" 1
expect_count "current_profile null" "current_profile: null" 1
expect_count "auto_switch off" "auto_switch_profiles: false" 1
expect_count_re "gpus top-level (Default)" "^gpus:$" 1
expect_count_re "profiles block" "^profiles:$" 1
expect_count_re "profile safe key" "^  safe:$" 1
expect_count_re "profile idle key" "^  idle:$" 1
expect_count_re "profile locked key" "^  locked:$" 1
expect_count_re "id A Default (2-space key)" "^  \"$ID_A\":$" 1
expect_count_re "id B Default (2-space key)" "^  \"$ID_B\":$" 1
expect_count_re "id A profiles (6-space key)" "^      \"$ID_A\":$" 3
expect_count_re "id B profiles (6-space key)" "^      \"$ID_B\":$" 3
expect_count "fan enabled (default+safe+locked)" "fan_control_enabled: true" 6
expect_count "fan disabled (idle)" "fan_control_enabled: false" 2
expect_count "fan_control_settings (default+safe+locked)" "fan_control_settings:" 6
expect_count "mode curve (default+locked)" "mode: curve" 4
expect_count "mode static (safe)" "mode: static" 2
expect_count "static speed safe 0.60" "static_speed: 0.60" 2
expect_count "no static 0.30 in curve mode" "static_speed: 0.30" 0
expect_count "curve 45 (default+safe+locked)" "45: 0.30" 6
expect_count "curve 65 (default+safe+locked)" "65: 0.40" 6
expect_count "curve 70 (default+safe+locked)" "70: 0.65" 6
expect_count "curve 75 (default+safe+locked)" "75: 0.80" 6
expect_count "temperature_key" "temperature_key: edge" 6
expect_count "interval_ms" "interval_ms: 500" 6
expect_count "power_cap 140 (default+locked)" "power_cap: 140" 4
expect_count "power_cap 120 (safe)" "power_cap: 120" 2
expect_count "power_cap 100 (idle)" "power_cap: 100" 2
expect_count "pm prefer-max (default+locked)" "power_mizer_mode: PreferMaximumPerformance" 4
expect_count "pm auto (safe+idle)" "power_mizer_mode: Auto" 4
expect_count "mem offsets block (default+locked)" "mem_clock_offsets:" 4
expect_count "offset pstate 0" "0: 2000" 4
expect_count "offset pstate 2" "2: 2000" 4
expect_count "offset pstate 3" "3: 2000" 4
expect_count "offset pstate 5" "5: 2000" 4
expect_count "offset pstate 8" "8: 2000" 4
expect_count "core lock min (locked)" "min_core_clock: 2000" 2
expect_count "core lock max (locked)" "max_core_clock: 2000" 2
expect_count "mem lock min (locked)" "min_memory_clock: 8500" 2
expect_count "mem lock max (locked)" "max_memory_clock: 8500" 2
expect_sec_count "default: no core lock" sec_default "min_core_clock" 0
expect_sec_count "default: no mem lock" sec_default "min_memory_clock" 0
expect_sec_count "safe: no offsets" sec_safe "mem_clock_offsets:" 0
expect_sec_count "safe: no locks" sec_safe "min_core_clock" 0
expect_sec_count "safe: no mem lock" sec_safe "min_memory_clock" 0
expect_sec_count "idle: no offsets" sec_idle "mem_clock_offsets:" 0
expect_sec_count "idle: no locks" sec_idle "min_core_clock" 0
expect_sec_count "idle: mem lock min 405" sec_idle "min_memory_clock: 405" 2
expect_sec_count "idle: mem lock max 405" sec_idle "max_memory_clock: 405" 2
expect_sec_count "idle: no fan_control_settings" sec_idle "fan_control_settings:" 0
expect_sec_count "idle: fan disabled x2" sec_idle "fan_control_enabled: false" 2
expect_sec_count "safe: curve present x2" sec_safe "curve:" 2
expect_sec_count "locked: power_cap 140 x2" sec_locked "power_cap: 140" 2
expect_sec_count "locked: core lock x2" sec_locked "min_core_clock: 2000" 2
expect_sec_count "locked: mem offsets x2" sec_locked "mem_clock_offsets:" 2
expect_sec_count "locked: pm prefer-max x2" sec_locked "power_mizer_mode: PreferMaximumPerformance" 2

expect_count "no gpu_clock_offsets by default" "gpu_clock_offsets:" 0
out=$(CORE_CLOCK_OFFSET=50 bash "$lact_sh" render "$PSTATES" "$ID_A $ID_B" 2>/dev/null) || { ko "env-core-off: render exit 0" "exit 0" "failed"; }
expect_count "env-core-off: gpu_clock_offsets x2 (Default only)" "gpu_clock_offsets:" 2
expect_count "env-core-off: pstate 0" "0: 50" 2
expect_count "env-core-off: pstate 2" "2: 50" 2
expect_count "env-core-off: pstate 3" "3: 50" 2
expect_count "env-core-off: pstate 5" "5: 50" 2
expect_count "env-core-off: pstate 8" "8: 50" 2
expect_sec_count "env-core-off: safe untouched" sec_safe "gpu_clock_offsets:" 0
expect_sec_count "env-core-off: idle untouched" sec_idle "gpu_clock_offsets:" 0
expect_sec_count "env-core-off: locked untouched" sec_locked "gpu_clock_offsets:" 0
out=$(CORE_CLOCK_OFFSET=-300 bash "$lact_sh" render "$PSTATES" "$ID_A $ID_B" 2>/dev/null) || { ko "env-core-off-neg: render exit 0" "exit 0" "failed"; }
expect_count "env-core-off-neg: pstate 0 -300 x2" "0: -300" 2
expect_count "env-core-off-neg: pstate 8 -300 x2" "8: -300" 2
out=$(PER_CARD_OVERRIDES="$ID_A|core_clock_offset=75" bash "$lact_sh" render "$PSTATES" "$ID_A $ID_B" 2>/dev/null) || { ko "ov-core-off: render exit 0" "exit 0" "failed"; }
expect_count "ov-core-off: id A 75 x1" "0: 75" 1
expect_count "ov-core-off: only 1 block (B=0)" "gpu_clock_offsets:" 1
out=$(CORE_CLOCK_OFFSET=50 PER_CARD_OVERRIDES="$ID_B|core_clock_offset=75" bash "$lact_sh" render "$PSTATES" "$ID_A $ID_B" 2>/dev/null) || { ko "ov-core-off2: render exit 0" "exit 0" "failed"; }
expect_count "ov-core-off2: id A 50 x1" "0: 50" 1
expect_count "ov-core-off2: id B 75 x1" "0: 75" 1
expect_count "ov-core-off2: blocks x2" "gpu_clock_offsets:" 2
rc=0; PER_CARD_OVERRIDES="$ID_A|core_clock_offset=abc" bash "$lact_sh" render "$PSTATES" "$ID_A $ID_B" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && ok "ov-core-off: non-numeric fails" || ko "ov-core-off: non-numeric fails" "non-zero exit" "exit 0"
rc=0; PER_CARD_OVERRIDES="$ID_A|core_clock_offset=-" bash "$lact_sh" render "$PSTATES" "$ID_A $ID_B" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && ok "ov-core-off: bare minus fails" || ko "ov-core-off: bare minus fails" "non-zero exit" "exit 0"

out=$(FAN_MODE=static bash "$lact_sh" render "$PSTATES" "$ID_A $ID_B" 2>/dev/null) || { ko "static: render exit 0" "exit 0" "failed"; }
expect_count "static: mode static x6" "mode: static" 6
expect_count "static: static_speed 0.30 x4" "static_speed: 0.30" 4
expect_count "static: static_speed 0.60 x2" "static_speed: 0.60" 2
expect_count "static: curve x6 (schema-required)" "curve:" 6
expect_count "static: curve 45 x6" "45: 0.30" 6
expect_count "static: curve 65 x6" "65: 0.40" 6
expect_count "static: curve 70 x6" "70: 0.65" 6
expect_count "static: curve 75 x6" "75: 0.80" 6

out=$(SAFE_PL=110 bash "$lact_sh" render "$PSTATES" "$ID_A $ID_B" 2>/dev/null) || { ko "env-safe-pl: render exit 0" "exit 0" "failed"; }
expect_count "env-safe-pl: 110 x2 (safe)" "power_cap: 110" 2
expect_count "env-safe-pl: 120 gone" "power_cap: 120" 0
out=$(IDLE_PL=110 bash "$lact_sh" render "$PSTATES" "$ID_A $ID_B" 2>/dev/null) || { ko "env-idle-pl: render exit 0" "exit 0" "failed"; }
expect_count "env-idle-pl: 110 x2 (idle)" "power_cap: 110" 2
expect_count "env-idle-pl: 100 gone" "power_cap: 100" 0
out=$(IDLE_MEM_CLOCK=0 bash "$lact_sh" render "$PSTATES" "$ID_A $ID_B" 2>/dev/null) || { ko "env-idle-mem-off: render exit 0" "exit 0" "failed"; }
expect_sec_count "env-idle-mem-off: no mem lock" sec_idle "min_memory_clock" 0
out=$(LOCKED_CORE_CLOCK=1900 bash "$lact_sh" render "$PSTATES" "$ID_A $ID_B" 2>/dev/null) || { ko "env-locked-core: render exit 0" "exit 0" "failed"; }
expect_count "env-locked-core: min 1900 x2" "min_core_clock: 1900" 2
expect_count "env-locked-core: max 1900 x2" "max_core_clock: 1900" 2
out=$(LOCKED_MEM_CLOCK=0 bash "$lact_sh" render "$PSTATES" "$ID_A $ID_B" 2>/dev/null) || { ko "env-locked-mem0: render exit 0" "exit 0" "failed"; }
expect_sec_count "env-locked-mem0: no mem lock" sec_locked "min_memory_clock" 0
expect_count "env-locked-mem0: core lock kept x2" "min_core_clock: 2000" 2
out=$(LOCKED_MEM_OFFSET=0 bash "$lact_sh" render "$PSTATES" "$ID_A $ID_B" 2>/dev/null) || { ko "env-locked-off0: render exit 0" "exit 0" "failed"; }
expect_sec_count "env-locked-off0: locked no offsets" sec_locked "mem_clock_offsets:" 0
expect_count "env-locked-off0: offsets total x2 (default)" "mem_clock_offsets:" 2

out=$(PER_CARD_OVERRIDES="$ID_A|power_cap=130" bash "$lact_sh" render "$PSTATES" "$ID_A $ID_B" 2>/dev/null) || { ko "ov-power: render exit 0" "exit 0" "failed"; }
expect_count "ov-power: id A Default 130" "power_cap: 130" 1
expect_count "ov-power: rest 140" "power_cap: 140" 3
expect_sec_count "ov-power: locked untouched x2" sec_locked "power_cap: 140" 2
out=$(PER_CARD_OVERRIDES="$ID_B|mem_clock_offset=500" bash "$lact_sh" render "$PSTATES" "$ID_A $ID_B" 2>/dev/null) || { ko "ov-mem: render exit 0" "exit 0" "failed"; }
expect_count "ov-mem: id B x2 (1000)" "0: 1000" 1
expect_count "ov-mem: id A + locked 2000" "0: 2000" 3
out=$(PER_CARD_OVERRIDES="$ID_A|safe_power_cap=110" bash "$lact_sh" render "$PSTATES" "$ID_A $ID_B" 2>/dev/null) || { ko "ov-safe-pl: render exit 0" "exit 0" "failed"; }
expect_count "ov-safe-pl: 110 x1" "power_cap: 110" 1
expect_count "ov-safe-pl: safe rest 120 x1" "power_cap: 120" 1
expect_sec_count "ov-safe-pl: default untouched" sec_default "power_cap: 140" 2
out=$(PER_CARD_OVERRIDES="$ID_A|locked_core_clock=1900" bash "$lact_sh" render "$PSTATES" "$ID_A $ID_B" 2>/dev/null) || { ko "ov-locked-core: render exit 0" "exit 0" "failed"; }
expect_count "ov-locked-core: min 1900 x1 (A only)" "min_core_clock: 1900" 1
expect_count "ov-locked-core: max 1900 x1 (A only)" "max_core_clock: 1900" 1
expect_count "ov-locked-core: rest 2000 x1" "min_core_clock: 2000" 1
out=$(PER_CARD_OVERRIDES="$ID_B|idle_power_cap=90" bash "$lact_sh" render "$PSTATES" "$ID_A $ID_B" 2>/dev/null) || { ko "ov-idle-pl: render exit 0" "exit 0" "failed"; }
expect_count "ov-idle-pl: 90 x1" "power_cap: 90" 1
expect_count "ov-idle-pl: idle rest 100 x1" "power_cap: 100" 1

rc=0; PER_CARD_OVERRIDES="$ID_A|bogus=1" bash "$lact_sh" render "$PSTATES" "$ID_A $ID_B" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && ok "ov: unknown field fails" || ko "ov: unknown field fails" "non-zero exit" "exit 0"
rc=0; PER_CARD_OVERRIDES="$ID_A|safe_pl=110" bash "$lact_sh" render "$PSTATES" "$ID_A $ID_B" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && ok "ov: unknown profile field fails" || ko "ov: unknown profile field fails" "non-zero exit" "exit 0"
rc=0; PER_CARD_OVERRIDES="power_cap=130" bash "$lact_sh" render "$PSTATES" "$ID_A $ID_B" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && ok "ov: entry without pipe fails" || ko "ov: entry without pipe fails" "non-zero exit" "exit 0"
rc=0; PER_CARD_OVERRIDES="|power_cap=130" bash "$lact_sh" render "$PSTATES" "$ID_A $ID_B" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && ok "ov: empty id fails" || ko "ov: empty id fails" "non-zero exit" "exit 0"
rc=0; bash "$lact_sh" render "" "$ID_A" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && ok "render: empty pstates fails" || ko "render: empty pstates fails" "non-zero exit" "exit 0"
rc=0; bash "$lact_sh" render "$PSTATES" "" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && ok "render: empty ids fails" || ko "render: empty ids fails" "non-zero exit" "exit 0"

# source check: the client shim line (lact-client v0.10.0 get_socket_path
# ignores LACT_DAEMON_SOCKET_PATH — cmd_daemon must point the hardcoded
# client path at the shared daemon socket)
shim_pat='ln -sfn "${LACT_DAEMON_SOCKET_PATH}" /run/lactd\.sock'
shim_got=$(grep -c -- "$shim_pat" "$lact_sh" || true)
if [ "$shim_got" -ge 1 ]; then
    ok "lact.sh: client shim (lact-client v0.10.0 ignores LACT_DAEMON_SOCKET_PATH)"
else
    ko "lact.sh: client shim (lact-client v0.10.0 ignores LACT_DAEMON_SOCKET_PATH)" \
       "line matching the shim pattern in lact.sh" "not found"
fi

echo "# pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
