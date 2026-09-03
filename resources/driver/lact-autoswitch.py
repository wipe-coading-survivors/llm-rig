#!/usr/bin/env python3
"""LACT profile auto-switch helper (spec stage 16 stage 2, variant B').

Loop: collect samples (llama /metrics -> load, nvidia-smi -> thermal,
`lact cli profile get` -> socket/actual) -> pure decide_* -> apply via the
shared LACT daemon socket -> history line. stdlib only (urllib, subprocess,
os). Importable module: functions without side effects, main() under the
__main__ guard (the offline test entry point).

Target space: {Default, safe, idle, FALLBACK, HOLD}; `locked` is never a
target (may be actual - operator apply, adopted on the next probe). The
helper never manages container lifecycles.
"""

import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

LLAMA_URL = os.environ.get("LLAMA_URL", "http://llama-cpp:8080")
LLAMA_MODEL = os.environ.get("LLAMA_MODEL", "default")
LLAMA_KEYS_FILE = os.environ.get("LLAMA_KEYS_FILE", "/etc/llama/llama-cpp-keys.txt")
KEY_MARKER = os.environ.get("KEY_MARKER", "lact-autoswitch")
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "5"))
THERMAL_EVERY = int(os.environ.get("THERMAL_EVERY", "3"))
TIME_IDLE = int(os.environ.get("TIME_IDLE", "120"))
TIME_DOWN = int(os.environ.get("TIME_DOWN", "300"))
TEMP_SAFE = int(os.environ.get("TEMP_SAFE", "82"))
TIME_SAFE_DUR = int(os.environ.get("TIME_SAFE_DUR", "300"))
TEMP_SAFE_BACK_DELTA = int(os.environ.get("TEMP_SAFE_BACK_DELTA", "4"))
TIME_SAFE_BACK_DUR = int(os.environ.get("TIME_SAFE_BACK_DUR", "300"))
TIME_DOWN_LACT = int(os.environ.get("TIME_DOWN_LACT", "60"))
FALLBACK_PL = int(os.environ.get("FALLBACK_PL", "120"))
HISTORY_LINES = int(os.environ.get("HISTORY_LINES", "2000"))
CRASH_PIN_COUNT = int(os.environ.get("CRASH_PIN_COUNT", "3"))
CRASH_PIN_WINDOW = int(os.environ.get("CRASH_PIN_WINDOW", "600"))
THERMAL_PIN_COUNT = int(os.environ.get("THERMAL_PIN_COUNT", "3"))
THERMAL_PIN_WINDOW = int(os.environ.get("THERMAL_PIN_WINDOW", "1800"))
PIN_LOG_EVERY = int(os.environ.get("PIN_LOG_EVERY", "300"))
PIN_FILE = os.environ.get("PIN_FILE", "/run/lact-autoswitch/pin")
CRASH_EVENTS_FILE = os.environ.get(
    "CRASH_EVENTS_FILE", "/run/lact-autoswitch/crashes")

HISTORY_FILE = "/run/lact-autoswitch/history.log"
LACT_BIN = "/usr/bin/lact"
SMI_BIN = "nvidia-smi"
METRICS_TIMEOUT = 5
SMI_TIMEOUT = 10
APPLY_TIMEOUT = 30
AUTH_STREAK_LIMIT = 10
SOCKET_PROFILES = ("Default", "safe", "idle", "locked")
TARGET_PROFILES = ("Default", "safe", "idle")


def log(msg):
    print("%s %s" % (time.strftime("%Y-%m-%dT%H:%M:%S"), msg), flush=True)


def alarm(msg):
    print("%s ALARM: %s" % (time.strftime("%Y-%m-%dT%H:%M:%S"), msg), flush=True)


# ---------- pure decide functions (offline-tested) ----------

def parse_metrics(body):
    """(requests_processing, requests_deferred) from a /metrics body;
    a missing gauge counts as 0. The metric name must match exactly
    (label braces stripped), so a name-suffix metric (e.g.
    llamacpp:requests_processing_foo) is never mistaken for a gauge."""
    p, d = 0.0, 0.0
    for line in body.splitlines():
        name = line.split(" ", 1)[0].split("{", 1)[0]
        if name == "llamacpp:requests_processing":
            p = float(line.rsplit(" ", 1)[1])
        elif name == "llamacpp:requests_deferred":
            d = float(line.rsplit(" ", 1)[1])
    return p, d


def load_sample(status, body):
    """One metrics probe -> 'B'/'I' (200), 'A' (401 or the 400 URL bug),
    'D' (refused/timeout = status -1, 400 not-loaded, anything else)."""
    if status == 200:
        p, d = parse_metrics(body)
        return "B" if (p > 0 or d > 0) else "I"
    if status == 401:
        return "A"
    if status == 400 and "name is missing" in body:
        return "A"
    return "D"


def is_url_bug(status, body):
    """400 'name is missing' = helper URL bug (alarm, sample A)."""
    return status == 400 and "name is missing" in body


def load_key(path, marker):
    """First non-empty non-comment line containing the marker (case
    sensitive); comment lines are skipped unconditionally. KeyError when
    absent (the caller exits 1 - fail-loud)."""
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if marker in line:
                return line
    raise KeyError("no line with marker %r in %s" % (marker, path))


def decide_load(window, n_idle, n_down):
    """'IDLE' on C1 (the last n_idle samples are all 'I') or C2 (the last
    n_down samples are all in {'I','D'}); else 'ACTIVE' - including a short
    or empty window (conservative after a helper restart). 'A' breaks both
    windows. window: oldest -> newest."""
    if len(window) >= n_idle and all(s == "I" for s in window[-n_idle:]):
        return "IDLE"
    if len(window) >= n_down and all(s in ("I", "D") for s in window[-n_down:]):
        return "IDLE"
    return "ACTIVE"


def decide_thermal(window, engaged, n_engage, n_release, temp_safe, back_delta):
    """One sticky bit: engage when the last n_engage samples are all >=
    temp_safe; release when the last n_release are all < temp_safe -
    back_delta; a mixed window leaves the bit unchanged (without it,
    oscillation around the threshold would never engage or release).
    window: oldest -> newest."""
    if not engaged:
        if len(window) >= n_engage and \
                all(t >= temp_safe for t in window[-n_engage:]):
            return True
        return False
    if len(window) >= n_release and \
            all(t < temp_safe - back_delta for t in window[-n_release:]):
        return False
    return True


def decide_target(socket_up, overtemp, auth_streak, load_state,
                  auth_limit=AUTH_STREAK_LIMIT):
    """Priority: thermal > auth > load; socket DOWN is a separate branch.
    -> 'safe' | 'Default' | 'idle' | 'FALLBACK' | 'HOLD'."""
    if not socket_up:
        return "FALLBACK" if overtemp else "HOLD"
    if overtemp:
        return "safe"
    if auth_streak >= auth_limit:
        return "Default"
    if load_state == "IDLE":
        return "idle"
    return "Default"


def read_crash_events(path, now, window):
    """[ts] integer lines with now-window < ts <= now; missing file ->
    [], non-integer lines ignored (watcher is the only writer)."""
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return []
    out = []
    for line in lines:
        try:
            ts = int(line.strip())
        except ValueError:
            continue
        if now - window < ts <= now:
            out.append(ts)
    return out


def decide_pin(crash_ts, now, crash_count, crash_window,
               thermal_ts, thermal_count, thermal_window, pinned):
    """(pin, reason, count, window); crashes take priority over
    thermal; no retrigger while pinned."""
    if pinned:
        return False, None, 0, 0
    recent_c = [t for t in crash_ts if now - crash_window < t <= now]
    if len(recent_c) >= crash_count:
        return True, "crashes", len(recent_c), crash_window
    recent_t = [t for t in thermal_ts if now - thermal_window < t <= now]
    if len(recent_t) >= thermal_count:
        return True, "thermal", len(recent_t), thermal_window
    return False, None, 0, 0


def parse_pin_file(path):
    """(ts, n, reason) from the pin file; missing/empty/unparseable ->
    (None, None, 'external'); partial parse is best-effort."""
    try:
        with open(path, encoding="utf-8") as f:
            line = f.readline().strip()
    except OSError:
        return None, None, "external"
    if not line:
        return None, None, "external"
    ts, n, reason = None, None, "external"
    for field in line.split():
        k, _, v = field.partition("=")
        if k == "ts":
            try:
                ts = int(v)
            except ValueError:
                pass
        elif k == "n":
            try:
                n = int(v)
            except ValueError:
                pass
        elif k == "reason":
            reason = v
    return ts, n, reason


def pin_log_due(now, last_block_log, every):
    """Block-log rate limit: first immediately, then >= every apart."""
    if last_block_log is None:
        return True
    return now - last_block_log >= every


def write_pin_file(path, reason, count, window, ts, n):
    """Atomic pin write (tmp + os.replace): one 'reason=... count=...
    window=... ts=... n=...' line."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("reason=%s count=%d window=%d ts=%d n=%d\n"
                % (reason, count, window, int(ts), n))
    os.replace(tmp, path)


class History:
    """Ring of 'epoch,load,thermal,socket,actual,target,switched' lines:
    append every cycle, trim to the cap (host tmpfs - a log, not
    persistent state)."""

    def __init__(self, path, cap):
        self.path = path
        self.cap = cap

    def _write_line(self, line):
        with open(self.path, "a", encoding="utf-8") as f:
            f.write(line)
        self._trim()

    def _trim(self):
        with open(self.path, encoding="utf-8") as f:
            lines = f.readlines()
        if len(lines) > self.cap:
            del lines[:len(lines) - self.cap]
            with open(self.path, "w", encoding="utf-8") as f:
                f.writelines(lines)

    def append(self, load, thermal, socket, actual, target, switched):
        self._write_line("%d,%s,%s,%s,%s,%s,%s\n" % (
            int(time.time()), load, thermal, socket, actual, target, switched))

    def restart_marker(self, actual):
        self._write_line("%d,RESTART,-,-,%s,-,-\n" % (int(time.time()), actual))


# ---------- live probes (not unit-tested) ----------

def poll_load(url, model, key):
    """(status, body); status -1 = refused/timeout."""
    req = urllib.request.Request(
        "%s/metrics?model=%s" % (url, model),
        headers={"Authorization": "Bearer " + key})
    try:
        with urllib.request.urlopen(req, timeout=METRICS_TIMEOUT) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception:
        return -1, ""


def poll_thermal():
    """(max temperature over all cards, ok) via nvidia-smi over the direct
    /dev/nvidia* nodes."""
    try:
        out = subprocess.run(
            [SMI_BIN, "--query-gpu=temperature.gpu",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=SMI_TIMEOUT)
    except Exception:
        return None, False
    if out.returncode != 0:
        return None, False
    temps = []
    for tok in out.stdout.replace(",", " ").split():
        try:
            temps.append(int(tok))
        except ValueError:
            continue
    if not temps:
        return None, False
    return max(temps), True


def probe_socket():
    """(up, actual) via `lact cli profile get` over the shared daemon
    socket; the CLI prints `Default` also for null."""
    try:
        out = subprocess.run(
            [LACT_BIN, "cli", "profile", "get"],
            capture_output=True, text=True, timeout=SMI_TIMEOUT)
    except Exception:
        return False, None
    if out.returncode != 0:
        return False, None
    name = out.stdout.strip()
    if name in SOCKET_PROFILES:
        return True, name
    return False, None


def apply_profile(name):
    """`lact cli profile set <name>` - synchronous RPC, returns after the
    daemon applied the profile; (ok, detail)."""
    try:
        out = subprocess.run(
            [LACT_BIN, "cli", "profile", "set", name],
            capture_output=True, text=True, timeout=APPLY_TIMEOUT)
    except Exception as e:
        return False, "exception: %s" % e
    if out.returncode != 0:
        return False, "rc=%d: %s" % (out.returncode, out.stderr.strip()[:200])
    return True, out.stdout.strip()


def smi_power_limits():
    """[power.limit W per card] or None on error."""
    try:
        out = subprocess.run(
            [SMI_BIN, "--query-gpu=power.limit", "--format=csv,noheader"],
            capture_output=True, text=True, timeout=SMI_TIMEOUT)
        if out.returncode != 0:
            return None
        vals = []
        for line in out.stdout.splitlines():
            tok = line.strip().split()[0]
            vals.append(float(tok))
        return vals or None
    except Exception:
        return None


def smi_card_defaults():
    """{card index: Default Power Limit W} via `nvidia-smi -i n -q -d POWER`
    per card (no CLI reset works under the resident llama context);
    None on any failure."""
    try:
        out = subprocess.run(
            [SMI_BIN, "--query-gpu=index", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=SMI_TIMEOUT)
        if out.returncode != 0:
            return None
        idxs = [l.strip() for l in out.stdout.splitlines() if l.strip()]
        res = {}
        for i in idxs:
            q = subprocess.run(
                [SMI_BIN, "-i", i, "-q", "-d", "POWER"],
                capture_output=True, text=True, timeout=SMI_TIMEOUT)
            if q.returncode != 0:
                return None
            for line in q.stdout.splitlines():
                s = line.strip()
                if s.startswith("Default Power Limit"):
                    res[i] = float(s.split(":", 1)[1].split()[0])
                    break
            else:
                return None
        return res
    except Exception:
        return None


def apply_fallback(pl):
    """`nvidia-smi -pm 1` + `nvidia-smi -pl <pl>` on all cards in one call
    ('safe without OC', fan - driver auto)."""
    try:
        subprocess.run([SMI_BIN, "-pm", "1"], capture_output=True,
                       text=True, timeout=SMI_TIMEOUT)
        out = subprocess.run([SMI_BIN, "-pl", str(pl)], capture_output=True,
                             text=True, timeout=SMI_TIMEOUT)
        return out.returncode == 0
    except Exception:
        return False


def release_fallback():
    """Per-card `nvidia-smi -i n -pl <default>` back to the driver defaults
    (expected: 4x170 + LHR 180)."""
    defaults = smi_card_defaults()
    if not defaults:
        return False
    for i in sorted(defaults):
        try:
            out = subprocess.run(
                [SMI_BIN, "-i", i, "-pl", str(int(defaults[i]))],
                capture_output=True, text=True, timeout=SMI_TIMEOUT)
            if out.returncode != 0:
                return False
        except Exception:
            return False
    return True


def install_client_shim(target, link):
    """lact-client v0.10.0: `lact cli` does not read LACT_DAEMON_SOCKET_PATH — it
    only checks the hardcoded /run/lactd.sock (root) or /run/user/<uid>/lactd.sock.
    Point the client path at the shared daemon socket."""
    if os.path.lexists(link):
        os.remove(link)
    os.symlink(target, link)


# ---------- main loop ----------

def main():
    sock_path = os.environ.get("LACT_DAEMON_SOCKET_PATH")
    if sock_path:
        install_client_shim(sock_path, "/run/lactd.sock")
    try:
        key = load_key(LLAMA_KEYS_FILE, KEY_MARKER)
    except (KeyError, OSError) as e:
        print("FATAL: keys: %s" % e, file=sys.stderr)
        return 1
    log("start: key found (marker %r), poll=%ds thermal-every=%d"
        % (KEY_MARKER, POLL_INTERVAL, THERMAL_EVERY))

    # window sizes (nominal period is kept by the loop; source timeouts are
    # guard limits, not the rhythm)
    n_idle = max(1, TIME_IDLE // POLL_INTERVAL)
    n_down = max(1, TIME_DOWN // POLL_INTERVAL)
    n_engage = max(1, TIME_SAFE_DUR // (THERMAL_EVERY * POLL_INTERVAL))
    n_release = max(1, TIME_SAFE_BACK_DUR // (THERMAL_EVERY * POLL_INTERVAL))
    n_lact = max(1, TIME_DOWN_LACT // POLL_INTERVAL)
    load_cap = n_down
    thermal_cap = max(n_engage, n_release)
    lact_cap = n_lact

    load_win = []
    thermal_win = []
    sock_win = []
    thermal = None
    thermal_errs = 0
    engaged = False
    auth_streak = 0
    fallback_on = False
    fb_alarm_armed = True
    lact_down_alarm = False
    pending = None
    pending_fails = 0
    pending_at = 0
    hist = History(HISTORY_FILE, HISTORY_LINES)
    _up0, actual0 = probe_socket()
    hist.restart_marker(actual0 if actual0 else "-")

    cyc = 0
    while True:
        cyc += 1
        # --- load sample (every cycle) ---
        status, body = poll_load(LLAMA_URL, LLAMA_MODEL, key)
        sample = load_sample(status, body)
        if is_url_bug(status, body):
            alarm("metrics: 400 'name is missing' - helper URL bug (%s)"
                  % LLAMA_URL)
        load_win.append(sample)
        if len(load_win) > load_cap:
            del load_win[:len(load_win) - load_cap]
        auth_streak = auth_streak + 1 if sample == "A" else 0
        if auth_streak == AUTH_STREAK_LIMIT:
            alarm("auth: %d consecutive 401 - forced target=Default "
                  "(keys rotation? llama restart?)" % auth_streak)

        # --- thermal (every THERMAL_EVERY cycles; on a failure the last
        #     value is the signal, a 4-in-a-row counter alarms) ---
        t_field = "-"
        if cyc % THERMAL_EVERY == 0:
            t, ok = poll_thermal()
            if ok:
                thermal = t
                thermal_errs = 0
            else:
                thermal_errs += 1
                if thermal_errs == 4:
                    alarm("nvidia-smi: 4 failures in a row (~1 min) - "
                          "keeping the last value")
            if thermal is not None:
                thermal_win.append(thermal)
                if len(thermal_win) > thermal_cap:
                    del thermal_win[:len(thermal_win) - thermal_cap]
                t_field = str(thermal)

        # --- socket/actual (every cycle) ---
        up, actual = probe_socket()
        sock_win.append("up" if up else "down")
        if len(sock_win) > lact_cap:
            del sock_win[:len(sock_win) - lact_cap]
        socket_state = "down" if (
            len(sock_win) >= n_lact and
            all(s == "down" for s in sock_win[-n_lact:])) else "up"
        if socket_state == "down" and not lact_down_alarm:
            alarm("socket: down for %ds (TIME_DOWN_LACT)" % TIME_DOWN_LACT)
            lact_down_alarm = True
        elif socket_state == "up":
            lact_down_alarm = False
            fb_alarm_armed = True

        # --- decide ---
        engaged = decide_thermal(thermal_win, engaged, n_engage, n_release,
                                 TEMP_SAFE, TEMP_SAFE_BACK_DELTA)
        load_state = decide_load(load_win, n_idle, n_down)
        target = decide_target(socket_state == "up", engaged, auth_streak,
                               load_state)
        if target == "FALLBACK":
            reason = "socket-down+overtemp"
        elif target == "HOLD":
            reason = "socket-down"
        elif engaged:
            reason = "overtemp"
        elif auth_streak >= AUTH_STREAK_LIMIT:
            reason = "auth-streak"
        elif load_state == "IDLE":
            reason = "idle"
        else:
            reason = "active"

        # --- apply ---
        switched = "-"
        if target in TARGET_PROFILES:
            if fallback_on:
                # socket up -> the daemon re-applies the whole profile
                # (PL/fan/offsets) and replaces the fallback PL
                fallback_on = False
                fb_alarm_armed = True
                log("fallback replaced by the profile switch (socket up)")
            if pending is not None and target != pending:
                pending = None
                pending_fails = 0
            if pending is None:
                if up and actual != target:
                    okset, detail = apply_profile(target)
                    if okset:
                        pending = target
                        pending_at = cyc
                        pending_fails = 0
                        switched = target
                        log("switch: %s -> %s (%s)"
                            % (actual, target, reason))
                    else:
                        pending_fails += 1
                        log("set %s failed: %s" % (target, detail))
                        if pending_fails >= 3:
                            alarm("apply %s: 3 failures in a row - GPU "
                                  "stays in the last real profile" % target)
                            pending_fails = 0
            else:
                if up and actual == pending:
                    log("verified: %s (%s)" % (pending, reason))
                    pending = None
                    pending_fails = 0
                elif (cyc - pending_at) % 3 == 0:
                    okset, detail = apply_profile(pending)
                    if okset:
                        pending_at = cyc
                    else:
                        pending_fails += 1
                        log("retry %s failed: %s" % (pending, detail))
                        if pending_fails >= 3:
                            alarm("apply %s: 3 failures in a row - GPU "
                                  "stays in the last real profile" % pending)
                            pending = None
                            pending_fails = 0
        elif target == "FALLBACK":
            if not fallback_on:
                limits = smi_power_limits()
                if limits is not None and any(
                        abs(l - FALLBACK_PL) >= 0.5 for l in limits):
                    if apply_fallback(FALLBACK_PL):
                        fallback_on = True
                        fb_alarm_armed = True
                        switched = "FALLBACK"
                        log("switch: -pl %d on all cards (%s)"
                            % (FALLBACK_PL, reason))
                    else:
                        if fb_alarm_armed:
                            alarm("fallback: nvidia-smi -pl %d failed"
                                  % FALLBACK_PL)
                            fb_alarm_armed = False
        else:  # HOLD
            if fallback_on and not engaged:
                if release_fallback():
                    fallback_on = False
                    fb_alarm_armed = True
                    log("fallback released: per-card default PL (socket "
                        "down, thermal bit released)")
                else:
                    if fb_alarm_armed:
                        alarm("fallback release failed (nvidia-smi)")
                        fb_alarm_armed = False

        # --- history ---
        hist.append(sample, t_field, socket_state,
                    actual if actual else "-", target, switched)
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    sys.exit(main())
