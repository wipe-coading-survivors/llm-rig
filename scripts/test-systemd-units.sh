#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
pass=0
fail=0

ok() { pass=$((pass + 1)); echo "ok - $1"; }
ko() { fail=$((fail + 1)); echo "not ok - $1"; echo "  expected: $2"; echo "  actual:   $3"; }

# Dual mode (the same /run/.containerenv detection as the Makefile CRE/HOST_ROOT):
# in toolbx the host channel is chroot /run/host (host systemd 259.7 sees the
# host /usr/bin/podman, so verify is clean); on the host — directly.
HOST_ROOT=""
[ -e /run/.containerenv ] && HOST_ROOT=/run/host

hostpath() {
    if [ -n "$HOST_ROOT" ]; then printf '%s%s' "$HOST_ROOT" "$1"; else printf '%s' "$1"; fi
}

analyze_verify() {
    if [ -n "$HOST_ROOT" ]; then
        chroot "$HOST_ROOT" /usr/bin/systemd-analyze verify "$@"
    else
        /usr/bin/systemd-analyze verify "$@"
    fi
}

u_kmod=$repo_root/resources/driver/nvidia-kmod.service
u_card=$repo_root/resources/driver/nvidia-card-setting.service
u_llama=$repo_root/resources/llama/llama-cpp.service
u_autoswitch=$repo_root/resources/driver/lact-autoswitch.service
u_mount=$repo_root/resources/systemd/var-local-llm.mount
services="$u_kmod $u_card $u_llama $u_autoswitch"

missing=""
for f in $services $u_mount; do
    [ -f "$f" ] || missing="$missing $f"
done
if [ -n "$missing" ]; then
    echo "not ok - artifacts present"
    echo "  missing:$missing"
    exit 1
fi

# --- 1. systemd-analyze verify: one invocation, all 5 files (cross-references
#     resolve within the passed set). Invariant: empty output — 259.7 returns
#     rc=0 even for a broken unit, so rc alone is not a signal.
args=""
for f in $services $u_mount; do
    args="$args $(hostpath "$f")"
done
out=$(analyze_verify $args 2>&1) || true
if [ -z "$out" ]; then
    ok "systemd-analyze verify: 5 artifacts, no warnings"
else
    ko "systemd-analyze verify: 5 artifacts, no warnings" "no output" "$out"
fi

# --- 2. static checks ---

# Active Exec lines: multi-line directives with continuations; commented
# lines (#ExecStart*) are excluded.
exec_lines() {
    awk '/^Exec/ { e = 1 } e { print } e && $0 !~ /\\$/ { e = 0 }' "$1"
}

for f in $services; do
    b=${f##*/}
    if exec_lines "$f" | grep -qF '$('; then
        ko "$b: Exec lines have no \$(...)" "no match" "$(exec_lines "$f" | grep -nF '$(')"
    else
        ok "$b: Exec lines have no \$(...)"
    fi
    if exec_lines "$f" | grep -qE '\$[A-Za-z_]'; then
        ko "$b: Exec lines have no bare \$VAR" "no match" "$(exec_lines "$f" | grep -nE '\$[A-Za-z_]')"
    else
        ok "$b: Exec lines have no bare \$VAR"
    fi
    if exec_lines "$f" | grep -qF '%'; then
        ko "$b: Exec lines have no % (specifier)" "no match" "$(exec_lines "$f" | grep -nF '%')"
    else
        ok "$b: Exec lines have no % (specifier)"
    fi
done

for f in $services; do
    b=${f##*/}
    if grep -qE '^EnvironmentFile=-' "$f"; then
        ko "$b: EnvironmentFile without '-'" "no '-' prefix" "$(grep -nE '^EnvironmentFile=-' "$f")"
    else
        ok "$b: EnvironmentFile without '-'"
    fi
    if [ "$(grep -cE '^EnvironmentFile=/etc/sysconfig/' "$f")" = "1" ]; then
        ok "$b: exactly one EnvironmentFile=/etc/sysconfig/"
    else
        ko "$b: exactly one EnvironmentFile=/etc/sysconfig/" "count=1" "count=$(grep -cE '^EnvironmentFile=/etc/sysconfig/' "$f" || true)"
    fi
    if grep -vE '^[[:space:]]*#' "$f" | grep -E 'Exec' | grep -qE 'nvidia-kmod-6|nvidia-lact-6|jupyter-torch-py310:|llama-cpp-cuda:'; then
        ko "$b: no hardcoded image tag in Exec" "no match" "$(grep -vE '^[[:space:]]*#' "$f" | grep -nE 'nvidia-kmod-6|nvidia-lact-6|jupyter-torch-py310:|llama-cpp-cuda:')"
    else
        ok "$b: no hardcoded image tag in Exec"
    fi
done

expect_grep() { # desc file ERE
    if grep -qE -- "$3" "$2"; then ok "$1"; else ko "$1" "grep -E '$3'" "no match in $2"; fi
}
expect_no_grep() { # desc file ERE
    if grep -qE -- "$3" "$2"; then ko "$1" "no match for '$3'" "$(grep -nE -- "$3" "$2")"; else ok "$1"; fi
}

# --- 3. nvidia-kmod.service ---
expect_grep "kmod: EnvironmentFile" "$u_kmod" '^EnvironmentFile=/etc/sysconfig/nvidia-kmod$'
expect_grep "kmod: ExecStartPre select script" "$u_kmod" '^ExecStartPre=/usr/local/bin/nvidia-kmod-select\.sh$'
expect_no_grep "kmod: no commented ExecStartPre" "$u_kmod" '^#ExecStartPre'
expect_grep "kmod: image \${KMOD_IMAGE}" "$u_kmod" '^[[:space:]]*\$\{KMOD_IMAGE\}[[:space:]]*\\$'
expect_grep "kmod: Type=oneshot" "$u_kmod" '^Type=oneshot$'
expect_grep "kmod: -v /dev:/dev" "$u_kmod" '^[[:space:]]*-v /dev:/dev[[:space:]]*\\$'
expect_grep "kmod: RemainAfterExit" "$u_kmod" '^RemainAfterExit=True$'
if exec_lines "$u_kmod" | grep -qF 'bash /create-devices.sh'; then
    ok "kmod: ExecStartPost create-devices (active)"
else
    ko "kmod: ExecStartPost create-devices (active)" "active Exec line with 'bash /create-devices.sh'" "$(exec_lines "$u_kmod")"
fi
if [ "$(exec_lines "$u_kmod" | grep -cF -- '--security-opt label=disable')" -ge 2 ]; then
    ok "kmod: label=disable in ExecStart and ExecStartPost"
else
    ko "kmod: label=disable in ExecStart and ExecStartPost" "count>=2 in active Exec lines" "$(exec_lines "$u_kmod" | grep -cF -- '--security-opt label=disable')"
fi

# --- 4. nvidia-card-setting.service ---
expect_no_grep "card-setting: no 'Serivce' typo" "$u_card" 'Serivce'
expect_grep "card-setting: EnvironmentFile" "$u_card" '^EnvironmentFile=/etc/sysconfig/nvidia-card-setting$'
expect_grep "card-setting: --name" "$u_card" '^[[:space:]]*--name nvidia-card-setting[[:space:]]*\\$'
expect_grep "card-setting: ExecStartPre rm -f" "$u_card" '^ExecStartPre=-/usr/bin/podman rm -f nvidia-card-setting$'
expect_grep "card-setting: image \${LACT_IMAGE}" "$u_card" '^[[:space:]]*\$\{LACT_IMAGE\}[[:space:]]*\\$'
expect_grep "card-setting: -e PWR_LIMIT" "$u_card" '^[[:space:]]*-e PWR_LIMIT=\$\{PWR_LIMIT\}[[:space:]]*\\$'
expect_grep "card-setting: -e MEM_CLOCK_OFFSET" "$u_card" '^[[:space:]]*-e MEM_CLOCK_OFFSET=\$\{MEM_CLOCK_OFFSET\}[[:space:]]*\\$'
expect_grep "card-setting: -e CORE_CLOCK_OFFSET" "$u_card" '^[[:space:]]*-e CORE_CLOCK_OFFSET=\$\{CORE_CLOCK_OFFSET\}[[:space:]]*\\$'
expect_grep "card-setting: -e FAN_MODE" "$u_card" '^[[:space:]]*-e FAN_MODE=\$\{FAN_MODE\}[[:space:]]*\\$'
expect_grep "card-setting: -e FAN_CURVE" "$u_card" '^[[:space:]]*-e FAN_CURVE=\$\{FAN_CURVE\}[[:space:]]*\\$'
expect_grep "card-setting: -e PER_CARD_OVERRIDES" "$u_card" '^[[:space:]]*-e PER_CARD_OVERRIDES=\$\{PER_CARD_OVERRIDES\}[[:space:]]*\\$'
expect_grep "card-setting: -e SAFE_PL" "$u_card" '^[[:space:]]*-e SAFE_PL=\$\{SAFE_PL\}[[:space:]]*\\$'
expect_grep "card-setting: -e SAFE_FAN_STATIC" "$u_card" '^[[:space:]]*-e SAFE_FAN_STATIC=\$\{SAFE_FAN_STATIC\}[[:space:]]*\\$'
expect_grep "card-setting: -e SAFE_PM_MODE" "$u_card" '^[[:space:]]*-e SAFE_PM_MODE=\$\{SAFE_PM_MODE\}[[:space:]]*\\$'
expect_grep "card-setting: -e IDLE_PL" "$u_card" '^[[:space:]]*-e IDLE_PL=\$\{IDLE_PL\}[[:space:]]*\\$'
expect_grep "card-setting: -e IDLE_PM_MODE" "$u_card" '^[[:space:]]*-e IDLE_PM_MODE=\$\{IDLE_PM_MODE\}[[:space:]]*\\$'
expect_grep "card-setting: -e IDLE_MEM_CLOCK" "$u_card" '^[[:space:]]*-e IDLE_MEM_CLOCK=\$\{IDLE_MEM_CLOCK\}[[:space:]]*\\$'
expect_grep "card-setting: -e LOCKED_CORE_CLOCK" "$u_card" '^[[:space:]]*-e LOCKED_CORE_CLOCK=\$\{LOCKED_CORE_CLOCK\}[[:space:]]*\\$'
expect_grep "card-setting: -e LOCKED_MEM_CLOCK" "$u_card" '^[[:space:]]*-e LOCKED_MEM_CLOCK=\$\{LOCKED_MEM_CLOCK\}[[:space:]]*\\$'
expect_grep "card-setting: -e LOCKED_MEM_OFFSET" "$u_card" '^[[:space:]]*-e LOCKED_MEM_OFFSET=\$\{LOCKED_MEM_OFFSET\}[[:space:]]*\\$'
expect_grep "card-setting: -e LOCKED_PL" "$u_card" '^[[:space:]]*-e LOCKED_PL=\$\{LOCKED_PL\}[[:space:]]*\\$'
expect_grep "card-setting: -e LOCKED_PM_MODE" "$u_card" '^[[:space:]]*-e LOCKED_PM_MODE=\$\{LOCKED_PM_MODE\}[[:space:]]*\\$'
expect_grep "card-setting: ExecStartPre mkdir /run/lactd (host tmpfs dir)" "$u_card" '^ExecStartPre=/usr/bin/mkdir -p /run/lactd$'
expect_grep "card-setting: ExecStartPre rm lactd.sock (stale after SIGKILL)" "$u_card" '^ExecStartPre=/usr/bin/rm -f /run/lactd/lactd\.sock$'
expect_grep "card-setting: -v /run/lactd (shared daemon socket)" "$u_card" '^[[:space:]]*-v /run/lactd:/run/lactd:z[[:space:]]*\\$'
expect_grep "card-setting: -e LACT_DAEMON_SOCKET_PATH" "$u_card" '^[[:space:]]*-e LACT_DAEMON_SOCKET_PATH=/run/lactd/lactd\.sock[[:space:]]*\\$'
expect_grep "card-setting: Restart=always" "$u_card" '^Restart=always$'
expect_no_grep "card-setting: no --rm" "$u_card" '(^|[[:space:]])--rm([[:space:]]|$)'
expect_no_grep "card-setting: no -i flag" "$u_card" '(^|[[:space:]])-i([[:space:]]|$)'
expect_no_grep "card-setting: no RemainAfterExit" "$u_card" '^RemainAfterExit'

# --- 6. llama-cpp.service ---
expect_grep "llama: Requires mount" "$u_llama" '^Requires=var-local-llm\.mount$'
expect_grep "llama: After includes mount" "$u_llama" '^After=.*var-local-llm\.mount$'
expect_grep "llama: EnvironmentFile" "$u_llama" '^EnvironmentFile=/etc/sysconfig/llama-cpp$'
expect_grep "llama: --name" "$u_llama" '^[[:space:]]*--name llama-cpp[[:space:]]*\\$'
expect_grep "llama: ExecStartPre rm -f" "$u_llama" '^ExecStartPre=-/usr/bin/podman rm -f llama-cpp$'
expect_grep "llama: image \${LLAMA_IMAGE}" "$u_llama" '\$\{LLAMA_IMAGE\} --port 8080'
expect_grep "llama: shm-size from sysconfig" "$u_llama" '\-\-shm-size=\$\{LLAMA_SHM_SIZE\}'
expect_grep "llama: host port from sysconfig" "$u_llama" '\-p \${LLAMA_PORT}:8080'
expect_grep "llama: /etc/llama mount" "$u_llama" '^[[:space:]]*-v /etc/llama:/root/llama:ro[[:space:]]*\\$'
expect_grep "llama: Restart=always" "$u_llama" '^Restart=always$'
expect_no_grep "llama: no CUDA_VISIBLE_DEVICES" "$u_llama" 'CUDA_VISIBLE_DEVICES'
expect_no_grep "llama: no --rm" "$u_llama" '(^|[[:space:]])--rm([[:space:]]|$)'
expect_no_grep "llama: no -i flag" "$u_llama" '(^|[[:space:]])-i([[:space:]]|$)'
expect_no_grep "llama: no RemainAfterExit" "$u_llama" '^RemainAfterExit'

# --- 7. var-local-llm.mount ---
expect_grep "mount: What" "$u_mount" '^What=@LLM_NFS_SERVER@:/mnt/sas/llm$'
expect_grep "mount: Where" "$u_mount" '^Where=/var/local/llm$'
expect_grep "mount: Type=nfs" "$u_mount" '^Type=nfs$'
expect_grep "mount: Options" "$u_mount" '^Options=vers=4\.2,hard,tcp$'
expect_grep "mount: WantedBy multi-user" "$u_mount" '^WantedBy=multi-user\.target$'

# --- 7a. lact-autoswitch.service ---
expect_grep "autoswitch: EnvironmentFile" "$u_autoswitch" '^EnvironmentFile=/etc/sysconfig/lact-autoswitch$'
expect_grep "autoswitch: --name" "$u_autoswitch" '^[[:space:]]*--name lact-autoswitch[[:space:]]*\\$'
expect_grep "autoswitch: ExecStartPre rm -f" "$u_autoswitch" '^ExecStartPre=-/usr/bin/podman rm -f lact-autoswitch$'
expect_grep "autoswitch: ExecStartPre mkdir host dirs" "$u_autoswitch" '^ExecStartPre=/usr/bin/mkdir -p /run/lactd /run/lact-autoswitch$'
expect_grep "autoswitch: label=disable" "$u_autoswitch" '--security-opt label=disable'
expect_grep "autoswitch: --privileged (fallback -pl write, fix round 5)" "$u_autoswitch" '^[[:space:]]*--privileged[[:space:]]*\\$'
if [ "$(grep -cE '^[[:space:]]*--device /dev/nvidia' "$u_autoswitch")" = "0" ]; then
    ok "autoswitch: no --device lines (superseded by --privileged)"
else
    ko "autoswitch: no --device lines (superseded by --privileged)" "count=0" "count=$(grep -cE '^[[:space:]]*--device /dev/nvidia' "$u_autoswitch" || true)"
fi
expect_grep "autoswitch: -v /run/lactd (socket)" "$u_autoswitch" '^[[:space:]]*-v /run/lactd:/run/lactd:z[[:space:]]*\\$'
expect_grep "autoswitch: -v /run/lact-autoswitch (history)" "$u_autoswitch" '^[[:space:]]*-v /run/lact-autoswitch:/run/lact-autoswitch:z[[:space:]]*\\$'
expect_grep "autoswitch: -v /etc/llama ro (key)" "$u_autoswitch" '^[[:space:]]*-v /etc/llama:/etc/llama:ro[[:space:]]*\\$'
expect_grep "autoswitch: -e LACT_DAEMON_SOCKET_PATH" "$u_autoswitch" '^[[:space:]]*-e LACT_DAEMON_SOCKET_PATH=/run/lactd/lactd\.sock[[:space:]]*\\$'
expect_grep "autoswitch: image \${LACT_AUTOSWITCH_IMAGE}" "$u_autoswitch" '^[[:space:]]*\$\{LACT_AUTOSWITCH_IMAGE\}[[:space:]]*\\$'
expect_grep "autoswitch: entrypoint python3 /lact-autoswitch.py" "$u_autoswitch" '^[[:space:]]*/usr/bin/python3 /lact-autoswitch\.py$'

# --- 8. common service parts ---
for f in $services; do
    b=${f##*/}
    expect_grep "$b: PODMAN_SYSTEMD_UNIT" "$f" '^Environment=PODMAN_SYSTEMD_UNIT=%n$'
    expect_grep "$b: RestartSec=30" "$f" '^RestartSec=30$'
    expect_grep "$b: WantedBy=default.target" "$f" '^WantedBy=default\.target$'
    expect_grep "$b: RequiresMountsFor" "$f" '^RequiresMountsFor=/run/containers/storage$'
done

echo "# pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
