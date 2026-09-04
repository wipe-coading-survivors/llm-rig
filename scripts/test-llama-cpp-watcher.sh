#!/bin/sh
# test-llama-cpp-watcher.sh — stage-10 prod zombie watcher: структурные
# пины (grep -F, фиксированные строки) + функциональные тесты (реальный
# скрипт против PATH-shim'ов journalctl/systemctl/podman). Офлайн, без
# контейнеров и сети. Харнес: паттерн scripts/test-safe-rm.sh.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
script=$repo_root/scripts/llama-cpp-watcher.sh
unit=$repo_root/resources/llama/llama-cpp-watcher.service
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

# --- 1. structural pins: the watcher script ---
check_count "kill trigger (container-level, spec-15 3.1)" "$script" 'podman kill "$CONTAINER"' 1
check_count "container binding" "$script" 'CONTAINER=llama-cpp' 1
check_count "unit binding" "$script" 'UNIT=llama-cpp' 1
check_count "zombie pattern" "$script" 'CUDA error: an illegal memory access' 1
check_count "zombie pattern 2 (D6, 30.08)" "$script" 'CUDA error: an internal operation failed' 1
check_count "journal unit scope" "$script" '-f -u "$UNIT"' 1
check_count "history scan" "$script" 'ActiveEnterTimestamp' 1
check_count "cooldown" "$script" 'COOLDOWN=120' 1
check_count "crash events file (stage 27)" "$script" 'CRASH_EVENTS_FILE=${CRASH_EVENTS_FILE:-/run/lact-autoswitch/crashes}' 1
check_count "crash events: mkdir events dir" "$script" 'mkdir -p "$(dirname "$CRASH_EVENTS_FILE")"' 1
check_count "crash events: trim 100 (tmp+mv)" "$script" 'tail -n 100 "$CRASH_EVENTS_FILE" > "$CRASH_EVENTS_FILE.tmp"' 1
check_count "no unit control: stop" "$script" 'systemctl stop' 0
check_count "no unit control: start" "$script" 'systemctl start' 0
check_count "no dmesg polling" "$script" 'dmesg' 0
check_count "no podman stop (stop-timeout class)" "$script" 'podman stop' 0

# --- 2. structural pins: the unit ---
check_count "unit: watcher auto-restart" "$unit" 'Restart=always' 1
check_count "unit: ExecStart" "$unit" 'ExecStart=/usr/local/bin/llama-cpp-watcher.sh' 1

# --- 3. structural pins: the Makefile (target systemd) ---
check_count "makefile: unit cp" "$makefile" 'resources/llama/llama-cpp-watcher.service' 1
check_count "makefile: script cp" "$makefile" 'scripts/llama-cpp-watcher.sh' 1
check_count "makefile: install path + enable" "$makefile" 'llama-cpp-watcher.service' 2
check_count "makefile: install path" "$makefile" 'usr/local/bin/llama-cpp-watcher.sh' 1

# --- 4. functional: the real script against PATH shims ---
# Shim'ы — фейковые бинари, перехватывающие вызовы watcher'а (не
# исполняют реальные CRE-инструменты).
shim_bin=$tmp/bin
mkdir -p "$shim_bin"

cat > "$shim_bin/journalctl" <<'SH'
#!/bin/sh
cat "${JOURNAL_LINES_FILE:?}"
exit 0
SH
chmod +x "$shim_bin/journalctl"

cat > "$shim_bin/systemctl" <<'SH'
#!/bin/sh
case "$1" in
    is-active) echo "${FAKE_UNIT_STATE:-active}" ;;
    show) echo "${FAKE_SINCE:-Sat 2026-08-30 10:00:00 MSK}" ;;
    *) echo "unexpected systemctl args: $*" >&2; exit 1 ;;
esac
SH
chmod +x "$shim_bin/systemctl"

FAKE_KILL_LOG=$tmp/kill.log
export FAKE_KILL_LOG
cat > "$shim_bin/podman" <<'SH'
#!/bin/sh
case "$1" in
    kill) echo "$*" >> "${FAKE_KILL_LOG:?}" ;;
    *) echo "unexpected podman args: $*" >&2; exit 1 ;;
esac
exit 0
SH
chmod +x "$shim_bin/podman"

reset_kill_log() {
    rm -f "$FAKE_KILL_LOG"
}

CRASH_EVENTS_FILE=$tmp/crashes
export CRASH_EVENTS_FILE

# desc, expected line count (file absent -> 0)
check_events() {
    desc=$1; want=$2
    if [ -f "$CRASH_EVENTS_FILE" ]; then
        got=$(wc -l < "$CRASH_EVENTS_FILE")
    else
        got=0
    fi
    if [ "$got" -eq "$want" ]; then
        ok "$desc"
    else
        ko "$desc" "$want lines" "$got lines; watcher: $(cat "$tmp/watcher.out" 2>/dev/null)"
    fi
}

# lines-file, unit-state; реальный watcher против shim'ов (фейковый
# journalctl завершается -> поток кончается -> watcher выходит)
run_watcher() {
    JOURNAL_LINES_FILE=$1 FAKE_UNIT_STATE=$2 \
        env PATH="$shim_bin:$PATH" bash "$script" >"$tmp/watcher.out" 2>&1 \
        || {
            ko "watcher run ($1, $2)" "rc=0" "rc=$?; $(cat "$tmp/watcher.out")"
            return 0
        }
}

# desc, expected number of 'kill llama-cpp' calls
check_kills() {
    desc=$1; want=$2
    if [ -f "$FAKE_KILL_LOG" ]; then
        got=$(grep -cF 'kill llama-cpp' "$FAKE_KILL_LOG" || true)
    else
        got=0
    fi
    if [ "$got" -eq "$want" ]; then
        ok "$desc"
    else
        ko "$desc" "$want kill(s)" "$got kill(s); watcher: $(cat "$tmp/watcher.out" 2>/dev/null)"
    fi
}

# 4.1 no-kill: обычные строки
reset_kill_log
printf '%s\n' \
    '[12345] 1.00.000.000 I slot print_timing: id 0 | task 1 | eval time = 100.0 ms' \
    '[12345] 1.00.001.000 I slot      release: id 0 | task 1 | stop processing: n_tokens = 10' \
    > "$tmp/lines-normal.txt"
run_watcher "$tmp/lines-normal.txt" active
check_kills "no-kill: normal lines" 0

# 4.2 kill: паттерн-строка, юнит active
reset_kill_log
{
    echo '[12345] 1.00.000.000 I slot print_timing: id 0 | task 1 | eval time = 100.0 ms'
    echo '[41763] 12.46.295.729 E CUDA error: an illegal memory access was encountered'
    echo '[12345] 1.00.002.000 I slot      release: id 0 | task 1 | stop processing: n_tokens = 10'
} > "$tmp/lines-pattern.txt"
run_watcher "$tmp/lines-pattern.txt" active
check_kills "kill: pattern line, unit active" 1

# 4.3 cooldown: две копии одной строки (отправители podman + llama-cpp)
reset_kill_log
{
    echo 'Aug 30 10:00:00 localhost llama-cpp[12345]: [41763] 12.46.295.729 E CUDA error: an illegal memory access was encountered'
    echo 'Aug 30 10:00:00 localhost podman[100]: [41763] 12.46.295.729 E CUDA error: an illegal memory access was encountered'
} > "$tmp/lines-double.txt"
run_watcher "$tmp/lines-double.txt" active
check_kills "cooldown: duplicate line -> single kill" 1

# 4.4 guard: юнит inactive (осознанный стоп)
reset_kill_log
run_watcher "$tmp/lines-pattern.txt" inactive
check_kills "guard: unit inactive -> no kill" 0

# 4.5 kill: 2-я паттерн-строка (internal operation failed — D6, 30.08;
# строка дословно из краха #4 каскада 22:08:58)
reset_kill_log
{
    echo '[12345] 1.00.000.000 I slot print_timing: id 0 | task 1 | eval time = 100.0 ms'
    echo '[43793] 0.26.217.467 E CUDA error: an internal operation failed'
} > "$tmp/lines-pattern2.txt"
run_watcher "$tmp/lines-pattern2.txt" active
check_kills "kill: pattern-2 line (internal operation failed), unit active" 1

# 4.6 crash events (stage 27): паттерн-строка -> 1 epoch-строка
reset_kill_log
rm -f "$CRASH_EVENTS_FILE"
run_watcher "$tmp/lines-pattern.txt" active
check_events "crash events: pattern line -> 1 event" 1

# 4.7 обычные строки -> файла нет
rm -f "$CRASH_EVENTS_FILE"
run_watcher "$tmp/lines-normal.txt" active
check_events "crash events: normal lines -> no file" 0

# 4.8 cooldown-дубли -> 1 событие
rm -f "$CRASH_EVENTS_FILE"
run_watcher "$tmp/lines-double.txt" active
check_events "crash events: duplicate line -> single event" 1

# 4.9 guard: юнит inactive -> ни kill, ни события
reset_kill_log
rm -f "$CRASH_EVENTS_FILE"
run_watcher "$tmp/lines-pattern.txt" inactive
check_kills "guard: unit inactive -> no kill (events)" 0
check_events "guard: unit inactive -> no event" 0

# 4.10 trim: 105 предзаполненных + 1 новое -> 100
seq 1 105 | while read -r n; do echo "$((1786000000 + n))"; done > "$CRASH_EVENTS_FILE"
run_watcher "$tmp/lines-pattern.txt" active
check_events "crash events: trim 106 -> 100" 100

# 4.11 mkdir -p несуществующего каталога (спека §6)
CRASH_EVENTS_FILE=$tmp/nested/dir/crashes
run_watcher "$tmp/lines-pattern.txt" active
check_events "crash events: mkdir -p nested dir" 1

echo "# pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
