#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
pass=0
fail=0

ok() { pass=$((pass + 1)); echo "ok - $1"; }
ko() { fail=$((fail + 1)); echo "not ok - $1"; echo "  expected: $2"; echo "  actual:   $3"; }

count() { grep -cF -- "$2" "$1" || true; }

check_count() { # desc file fixed-string expected
    actual=$(count "$2" "$3")
    if [ "$actual" = "$4" ]; then ok "$1"; else ko "$1" "$4" "$actual"; fi
}

run="$repo_root/debug/llama-run.sh"
send="$repo_root/debug/llama-send.py"
repro="$repo_root/debug/repro-llama-block3-run.sh"
agents="$repo_root/AGENTS.md"

# --- syntax ---
if bash -n "$run"; then ok "llama-run.sh: bash -n"; else ko "llama-run.sh: bash -n" "rc=0" "syntax error"; fi
if bash -n "$repro"; then ok "repro-llama-block3-run.sh: bash -n"; else ko "repro-llama-block3-run.sh: bash -n" "rc=0" "syntax error"; fi
if python3 - "$send" <<'PY'
import ast, sys
ast.parse(open(sys.argv[1]).read())
PY
then ok "llama-send.py: syntax"; else ko "llama-send.py: syntax" "rc=0" "syntax error"; fi

# --- llama-run.sh: mirror of the llama-cpp.service unit ---
check_count "llama-run.sh: no CUDA_VISIBLE_DEVICES" "$run" 'CUDA_VISIBLE_DEVICES' 0
check_count "llama-run.sh: no llama-cpp-numa" "$run" 'llama-cpp-numa' 0
check_count "llama-run.sh: no --rm" "$run" '--rm' 0
check_count "llama-run.sh: no -ti" "$run" '-ti' 0
check_count "llama-run.sh: named container" "$run" '--name llama-cpp' 1
check_count "llama-run.sh: rm -f before run" "$run" 'rm -f llama-cpp' 1
check_count "llama-run.sh: /etc/llama mount" "$run" '-v /etc/llama:/llama:ro' 1
check_count "llama-run.sh: CRE detection kept" "$run" '/run/.containerenv' 1
check_count "llama-run.sh: shm-size 1g" "$run" '--shm-size=1g' 1
check_count "llama-run.sh: non-root user" "$run" '-u 1001001:0' 1
check_count "llama-run.sh: memory limit 120g" "$run" '-m 120g' 1
check_count "llama-run.sh: memlock ulimit" "$run" '--ulimit memlock=-1:-1' 1
check_count "llama-run.sh: nvidiactl device" "$run" '--device /dev/nvidiactl' 1
check_count "llama-run.sh: nvidia-uvm device" "$run" '--device /dev/nvidia-uvm' 1
check_count "llama-run.sh: no --privileged" "$run" '--privileged' 0
check_count "llama-run.sh: models-preset /llama" "$run" '--models-preset /llama/llama.ini' 1

# --- llama-send.py: KEYFILE branch by /run/.containerenv ---
check_count "llama-send.py: containerenv branch" "$send" 'os.path.isfile("/run/.containerenv")' 1
check_count "llama-send.py: toolbx key path" "$send" '"/run/host/etc/llama/llama-cpp-keys.txt"' 1
check_count "llama-send.py: host key path" "$send" '"/etc/llama/llama-cpp-keys.txt"' 1

# --- repro-llama-block3-run.sh: stage-14 paths + stage-15 unit-aware prod control ---
check_count "repro: /etc/llama mount /llama (C2)" "$repro" '-v /etc/llama:/llama:ro' 1
check_count "repro: /etc/llama mounts /root/llama (stubs x2)" "$repro" '-v /etc/llama:/root/llama:ro' 2
check_count "repro: C2 models-preset /llama" "$repro" '--models-preset /llama/llama.ini' 1
check_count "repro: no llama-cpp-numa" "$repro" 'llama-cpp-numa' 0
check_count "repro: PROD=llama-cpp" "$repro" 'PROD=llama-cpp' 1
check_count "repro: no CUDA_VISIBLE_DEVICES" "$repro" 'CUDA_VISIBLE_DEVICES' 0
check_count "repro: SYSCTL chroot wrapper" "$repro" 'chroot $HOST_ROOT /usr/bin/systemctl' 1
check_count "repro: sysctl stop llama-cpp" "$repro" 'SYSCTL stop llama-cpp' 1
check_count "repro: sysctl start llama-cpp" "$repro" 'SYSCTL start llama-cpp' 1
check_count "repro: is-active checks" "$repro" 'SYSCTL is-active llama-cpp' 3
check_count "repro: no podman stop of prod" "$repro" 'stop -t 30' 0
check_count "repro: no rm -f of prod container" "$repro" 'rm -f "$PROD"' 0
check_count "repro: no llama-run.sh call" "$repro" 'bash debug/llama-run.sh' 0

# --- AGENTS.md: rename ---
check_count "AGENTS.md: no llama-cpp-numa" "$agents" 'llama-cpp-numa' 0
check_count "AGENTS.md: section header llama-cpp" "$agents" '## Логи llama-server (llama-cpp)' 1

echo "# pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
