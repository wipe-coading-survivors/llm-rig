#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lact_sh="$repo_root/resources/driver/lact/lact.sh"

if [ ! -f "$lact_sh" ]; then
    echo "not ok - lact.sh exists"
    exit 1
fi

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok - $1"; }
ko() { fail=$((fail + 1)); echo "not ok - $1"; echo "  expected: $2"; echo "  actual:   $3"; }

sandbox=
cleanup() {
    if [ -n "$sandbox" ]; then
        "$repo_root/scripts/safe-rm" --under "$(dirname "$sandbox")" "$sandbox" 2>/dev/null || true
    fi
}
trap cleanup EXIT

write_info_json() {
    cat > "$1" <<'EOF'
{
  "system_info": null,
  "devices": {
    "TESTID_A": {
      "clocks_info": {
        "max_sclk": 2100,
        "max_mclk": 7501,
        "table": {
          "type": "nvidia",
          "value": {
            "mem_offsets": {
              "0": {
                "current": 2000,
                "min": -2000,
                "max": 2000
              },
              "2": {
                "current": 2000,
                "min": -2000,
                "max": 2000
              },
              "3": {
                "current": 2000,
                "min": -2000,
                "max": 2000
              },
              "5": {
                "current": 2000,
                "min": -2000,
                "max": 2000
              },
              "8": {
                "current": 2000,
                "min": -2000,
                "max": 2000
              }
            }
          }
        }
      }
    }
  }
}
EOF
}

write_fake_nvidia_smi() {
    cat > "$1/bin/nvidia-smi" <<'EOF'
#!/bin/bash
set -eu
T=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
case "$*" in
    *-pm\ 1*)
        exit 0
        ;;
    *--query-gpu=clocks.max.memory*)
        printf '%s\n' "7501 MHz"
        ;;
    *--query-gpu=fan.speed*)
        printf '%s\n' "30"
        ;;
    *--query-gpu=clocks.current.memory*)
        n=$(cat "$T/cnt")
        n=$((n + 1))
        printf '%s\n' "$n" > "$T/cnt"
        line=$(sed -n "${n}p" "$T/seq")
        [ -n "$line" ] || line=$(tail -n 1 "$T/seq")
        printf '%s\n' "$line"
        ;;
    *--query-gpu=power.limit*)
        printf '%s\n' "100.00 W"
        ;;
    *-q\ -d\ POWER*)
        printf '%s\n' "    Power Management Mode    : Auto"
        ;;
    *)
        exit 0
        ;;
esac
EOF
    chmod 755 "$1/bin/nvidia-smi"
}

write_fake_lact() {
    cat > "$1/bin/lact" <<'EOF'
#!/bin/bash
set -eu
T=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
case "${1:-} ${2:-}" in
    "cli list")
        printf '%s\n' "0 TESTID_A" "1 TESTID_B"
        ;;
    "cli snapshot")
        printf '%s\n' "Generated debug snapshot in $T/snap.tar.gz"
        ;;
    "cli profile")
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
    chmod 755 "$1/bin/lact"
}

check_substr() {
    log=$1
    substr=$2
    what=$3
    if grep -qF -- "$substr" "$log"; then
        ok "$name: $what contains '$substr'"
    else
        ko "$name: $what contains '$substr'" "substring in $what" "$what tail: $(tail -n 3 "$log" | tr '\n' '|')"
    fi
}

run_case() {
    name=$1
    seq_args=$2
    want_rc=$3
    want_cnt=$4
    want_out1=$5
    want_out2=$6
    want_err=$7
    profile=${8:-idle}
    env_extra=${9:-}

    sandbox=$(mktemp -d)
    T=$sandbox
    mkdir -p "$T/bin" "$T/snapdir"
    write_fake_nvidia_smi "$T"
    write_fake_lact "$T"
    printf '0\n' > "$T/cnt"
    printf '%s\n' $seq_args > "$T/seq"
    : > "$T/daemon.log"
    write_info_json "$T/snapdir/info.json"
    tar -C "$T/snapdir" -czf "$T/snap.tar.gz" info.json

    (
        while [ ! -f "$T/config.yaml" ]; do
            sleep 0.1
        done
        sleep 0.2
        echo "configuration reloaded" >> "$T/daemon.log"
    ) &
    app=$!

    rc=0
    env $env_extra \
        LACT_BIN="$T/bin/lact" \
        DAEMON_LOG="$T/daemon.log" \
        CONFIG_FILE="$T/config.yaml" \
        SELF_CHECK_RETRIES=3 \
        SELF_CHECK_SLEEP=0.2 \
        PATH="$T/bin:$PATH" \
        bash "$lact_sh" apply "$profile" > "$T/out.log" 2> "$T/err.log" || rc=$?

    kill "$app" 2>/dev/null || true
    wait "$app" 2>/dev/null || true

    if [ "$want_rc" = "0" ]; then
        if [ "$rc" -eq 0 ]; then
            ok "$name: rc=0"
        else
            ko "$name: rc=0" "rc=0" "rc=$rc (stderr tail: $(tail -n 1 "$T/err.log" | tr '\n' '|'))"
        fi
    else
        if [ "$rc" -ne 0 ]; then
            ok "$name: rc!=0"
        else
            ko "$name: rc!=0" "non-zero rc" "rc=0 (stdout tail: $(tail -n 1 "$T/out.log" | tr '\n' '|'))"
        fi
    fi

    if [ -n "$want_out1" ]; then
        check_substr "$T/out.log" "$want_out1" "stdout"
    fi
    if [ -n "$want_out2" ]; then
        check_substr "$T/out.log" "$want_out2" "stdout"
    fi
    if [ -n "$want_err" ]; then
        check_substr "$T/err.log" "$want_err" "stderr"
    fi

    got_cnt=$(cat "$T/cnt")
    if [ "$got_cnt" = "$want_cnt" ]; then
        ok "$name: clocks.current.memory queries = $want_cnt"
    else
        ko "$name: clocks.current.memory queries = $want_cnt" "cnt=$want_cnt" "cnt=$got_cnt"
    fi

    "$repo_root/scripts/safe-rm" --under "$(dirname "$sandbox")" "$sandbox" 2>/dev/null || true
    sandbox=
}

run_case "retry-then-ok" "7301 8301 405" "0" "3" \
    "self-check: OK (profile=idle" "cur.mem=405 MHz" ""
run_case "first-try-ok" "405" "0" "1" "" "" ""
run_case "never-settles" "7301" "nonzero" "3" "" "" \
    "did not settle after 3 attempts"
# Default: expect = 7501 + MEM_CLOCK_OFFSET (D3, stage 10 live window:
# hardcoded 8501 broke apply on prod with MEM_CLOCK_OFFSET=1100 -> 8601)
run_case "default-ok" "" "0" "0" \
    "self-check: OK (profile=Default, max.mem=7501 MHz" "" "" \
    "Default" "PWR_LIMIT=100 MEM_CLOCK_OFFSET=0"
run_case "default-mismatch" "" "nonzero" "0" "" "" \
    "expect 8501" "Default" "PWR_LIMIT=100"

echo "# pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
