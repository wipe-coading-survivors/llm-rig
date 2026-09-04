#!/usr/bin/env python3
"""Offline TDD for the LACT autoswitch helper (spec stage 16 stage 2,
§6.1). TAP: ok / not ok + "# pass=N fail=N". The helper module is loaded
by path via importlib (hyphen in the file name - `import` is impossible);
functions are tested in purity, no containers/devices.
"""

import importlib.util
import os
import re
import shutil
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD_PATH = os.path.join(REPO, "resources", "driver", "lact-autoswitch.py")

PASS = 0
FAIL = 0


def ok(desc):
    global PASS
    PASS += 1
    print("ok - %s" % desc)


def ko(desc, expected, actual):
    global FAIL
    FAIL += 1
    print("not ok - %s" % desc)
    print("  expected: %s" % expected)
    print("  actual:   %s" % actual)


def check(desc, got, want):
    if got == want:
        ok(desc)
    else:
        ko(desc, repr(want), repr(got))


try:
    spec = importlib.util.spec_from_file_location("lact_autoswitch", MOD_PATH)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
except Exception as e:
    print("not ok - module loads")
    print("  expected: %s importable" % MOD_PATH)
    print("  actual:   %s: %s" % (type(e).__name__, e))
    print("# pass=0 fail=1")
    sys.exit(1)
ok("module loads")

check("SMI_BIN is the bare PATH name (no hardcoded prefix)", m.SMI_BIN, "nvidia-smi")

tmpd = tempfile.mkdtemp(prefix="lact-autoswitch-test.")
try:
    # --- parse_metrics / load_sample / is_url_bug (spec §3.1) ---
    check("metrics: processing 3, deferred 4",
          m.parse_metrics("llamacpp:requests_processing 3\n"
                          "llamacpp:requests_deferred 4\n"), (3.0, 4.0))
    check("metrics: missing gauges -> 0",
          m.parse_metrics("llamacpp:other 1\n"), (0.0, 0.0))
    check("metrics: name-suffix metric ignored (exact name match)",
          m.parse_metrics("llamacpp:requests_processing_x 7\n"
                          "llamacpp:requests_deferred 2\n"), (0.0, 2.0))
    check("load: 200 + processing>0 -> B",
          m.load_sample(200, "llamacpp:requests_processing 1\n"
                             "llamacpp:requests_deferred 0\n"), "B")
    check("load: 200 + deferred>0 -> B",
          m.load_sample(200, "llamacpp:requests_processing 0\n"
                             "llamacpp:requests_deferred 2\n"), "B")
    check("load: 200 + 0/0 -> I",
          m.load_sample(200, "llamacpp:requests_processing 0\n"
                             "llamacpp:requests_deferred 0\n"), "I")
    check("load: 401 -> A", m.load_sample(401, ""), "A")
    check("load: 400 not loaded -> D",
          m.load_sample(400, "model is not loaded"), "D")
    check("load: 400 name missing -> A (URL bug)",
          m.load_sample(400, "name is missing"), "A")
    check("load: refused/timeout (-1) -> D", m.load_sample(-1, ""), "D")
    check("load: 500 -> D", m.load_sample(500, ""), "D")
    check("url-bug: only 400 + name missing",
          (m.is_url_bug(400, "name is missing"),
           m.is_url_bug(400, "model is not loaded"),
           m.is_url_bug(200, "name is missing")), (True, False, False))

    # --- decide-load (spec §3.2: C1/C2, A breaks both windows) ---
    check("load C1: 24xI -> IDLE", m.decide_load(["I"] * 24, 24, 60), "IDLE")
    check("load C2: 60xD -> IDLE", m.decide_load(["D"] * 60, 24, 60), "IDLE")
    check("load: single B in the last 24 -> ACTIVE",
          m.decide_load(["I"] * 23 + ["B"], 24, 60), "ACTIVE")
    check("load: 59xD (< TIME_DOWN) -> ACTIVE",
          m.decide_load(["D"] * 59, 24, 60), "ACTIVE")
    check("load: mixed {I,D} x60, no B -> IDLE",
          m.decide_load(["I", "D"] * 30, 24, 60), "IDLE")
    check("load: B within 60 -> ACTIVE",
          m.decide_load(["I"] * 59 + ["B"], 24, 60), "ACTIVE")
    check("load: A breaks both windows -> ACTIVE",
          m.decide_load(["I"] * 30 + ["A"], 24, 60), "ACTIVE")
    check("load: empty window -> ACTIVE (after a helper restart)",
          m.decide_load([], 24, 60), "ACTIVE")
    check("load C2: B older than n_down, last 60 all {I,D} -> IDLE",
          m.decide_load(["B"] + ["I", "D"] * 30, 24, 60), "IDLE")
    check("load C2: B inside the last 60 -> ACTIVE (control)",
          m.decide_load(["I", "D"] * 29 + ["I", "B"], 24, 60), "ACTIVE")

    # --- decide-thermal (spec §3.2: one sticky bit; 82/4 = prod) ---
    check("thermal: 20x82 -> engage",
          m.decide_thermal([82] * 20, False, 20, 20, 82, 4), True)
    check("thermal: 19x82 + 1x81 -> no engage",
          m.decide_thermal([82] * 19 + [81], False, 20, 20, 82, 4), False)
    check("thermal: engaged + mixed window -> sticky",
          m.decide_thermal([85] * 10 + [80] * 10, True, 20, 20, 82, 4), True)
    check("thermal: engaged + 20x<78 -> release",
          m.decide_thermal([77] * 20, True, 20, 20, 82, 4), False)
    check("thermal: engaged + 19x<78 + 1x78 -> sticky",
          m.decide_thermal([77] * 19 + [78], True, 20, 20, 82, 4), True)
    check("thermal: single spike 90 -> no engage",
          m.decide_thermal([90], False, 20, 20, 82, 4), False)
    check("thermal boundary: 20x81 -> no engage",
          m.decide_thermal([81] * 20, False, 20, 20, 82, 4), False)
    check("thermal: short window (5x85) -> no engage",
          m.decide_thermal([85] * 5, False, 20, 20, 82, 4), False)

    # --- decide_target (spec §3.3: thermal > auth > load; DOWN = branch) ---
    check("target: OVERTEMP+ACTIVE -> safe",
          m.decide_target(True, True, 0, "ACTIVE"), "safe")
    check("target: OVERTEMP+IDLE -> safe",
          m.decide_target(True, True, 0, "IDLE"), "safe")
    check("target: socket DOWN+OVERTEMP -> FALLBACK",
          m.decide_target(False, True, 0, "IDLE"), "FALLBACK")
    check("target: socket DOWN+OK -> HOLD",
          m.decide_target(False, False, 0, "ACTIVE"), "HOLD")
    check("target: auth-streak(10)+IDLE -> Default",
          m.decide_target(True, False, 10, "IDLE"), "Default")
    check("target: auth-streak+OVERTEMP -> safe (thermal beats auth)",
          m.decide_target(True, True, 10, "ACTIVE"), "safe")
    check("target: ACTIVE, no overtemp/streak -> Default",
          m.decide_target(True, False, 0, "ACTIVE"), "Default")
    check("target: IDLE, no overtemp/streak -> idle",
          m.decide_target(True, False, 0, "IDLE"), "idle")
    check("target: custom auth_limit=3, streak 3 -> Default",
          m.decide_target(True, False, 3, "IDLE", auth_limit=3), "Default")
    check("target: custom auth_limit=3, streak 2 -> idle",
          m.decide_target(True, False, 2, "IDLE", auth_limit=3), "idle")
    check("target: streak 9 (< 10) + IDLE -> idle",
          m.decide_target(True, False, 9, "IDLE"), "idle")

    # --- key parsing (spec §3.1) ---
    keys = os.path.join(tmpd, "keys.txt")
    with open(keys, "w") as f:
        f.write("# prod key\n")
        f.write("prodkey-abcdef0123456789\n")
        f.write("\n")
        f.write("# helper: lact-autoswitch\n")
        f.write("lact-autoswitch-0123456789abcdef0123456789abcdef\n")
        f.write("lact-autoswitch-ffffffffffffffffffffffffffffffff\n")
    check("key: first marker line, #/empty/other skipped",
          m.load_key(keys, "lact-autoswitch"),
          "lact-autoswitch-0123456789abcdef0123456789abcdef")

    keys2 = os.path.join(tmpd, "keys-nomarker.txt")
    with open(keys2, "w") as f:
        f.write("# helper: lact-autoswitch\n")
        f.write("prodkey-abcdef0123456789\n")
    try:
        m.load_key(keys2, "lact-autoswitch")
        check("key: marker only in a comment -> fail", "KeyError", "no error")
    except KeyError:
        ok("key: marker only in a comment -> fail")

    keys3 = os.path.join(tmpd, "keys-empty.txt")
    with open(keys3, "w") as f:
        pass
    try:
        m.load_key(keys3, "lact-autoswitch")
        check("key: no marker -> fail", "KeyError", "no error")
    except KeyError:
        ok("key: no marker -> fail")

    # --- history ring (spec §4.1) ---
    hpath = os.path.join(tmpd, "history.log")
    h = m.History(hpath, 5)
    for s in ["B", "I", "D", "A", "D", "A", "I", "B"]:
        h.append(s, "-", "up", "Default", "Default", "-")
    with open(hpath) as f:
        lines = f.readlines()
    check("ring: trimmed to the cap (8 appends, cap 5)", len(lines), 5)
    check("ring: last 5 kept, oldest 3 dropped",
          [l.split(",")[1] for l in lines], ["A", "D", "A", "I", "B"])
    check("ring: line format epoch,load,thermal,socket,actual,target,switched",
          bool(re.match(r"^\d+,A,-,up,Default,Default,-$", lines[0])), True)
    rpath = os.path.join(tmpd, "restart.log")
    m.History(rpath, 5).restart_marker("Default")
    with open(rpath) as f:
        rline = f.readline()
    check("ring: RESTART line format",
          bool(re.match(r"^\d+,RESTART,-,-,Default,-,-$", rline)), True)

    # --- client shim (lact-client v0.10.0: `lact cli` does not read
    #     LACT_DAEMON_SOCKET_PATH — it only checks the hardcoded
    #     /run/lactd.sock; the shim points the client path at the shared
    #     daemon socket) ---
    with tempfile.TemporaryDirectory(prefix="lact-shim-test.") as shd:
        target = os.path.join(shd, "real.sock")
        link = os.path.join(shd, "lactd.sock")
        shim_descs = (
            "shim: creates a symlink to the target",
            "shim: idempotent (second call)",
            "shim: replaces an existing regular file",
        )
        try:
            m.install_client_shim(target, link)
            check(shim_descs[0],
                  (os.path.islink(link), os.readlink(link)), (True, target))
            m.install_client_shim(target, link)
            check(shim_descs[1],
                  (os.path.islink(link), os.readlink(link)), (True, target))
            with open(link, "w") as f:
                f.write("stale")
            m.install_client_shim(target, link)
            check(shim_descs[2],
                  (os.path.islink(link), os.readlink(link)), (True, target))
        except AttributeError as e:
            for d in shim_descs:
                ko(d, "install_client_shim defined",
                   "AttributeError: %s" % e)

    # --- stage 27: pin (spec 2026-09-03-stage27-pin-safe-design.md) ---
    pin_desc = ("pin: pure functions defined (decide_pin, "
                "read_crash_events, parse_pin_file, pin_log_due, "
                "write_pin_file)")
    try:
        NOW = 1786000000
        CW, TW = 600, 1800

        check("decide_pin: below crash threshold",
              m.decide_pin([NOW - 100, NOW - 50], NOW, 3, CW, [], 3, TW, False),
              (False, None, 0, 0))
        check("decide_pin: crash threshold reached",
              m.decide_pin([NOW - 100, NOW - 50, NOW - 10], NOW, 3, CW, [], 3, TW, False),
              (True, "crashes", 3, CW))
        check("decide_pin: old events outside window",
              m.decide_pin([NOW - 601, NOW - 700, NOW - 800], NOW, 3, CW, [], 3, TW, False),
              (False, None, 0, 0))
        check("decide_pin: future ts ignored",
              m.decide_pin([NOW + 5, NOW + 6, NOW + 7], NOW, 3, CW, [], 3, TW, False),
              (False, None, 0, 0))
        check("decide_pin: thermal threshold",
              m.decide_pin([], NOW, 3, CW, [NOW - 100, NOW - 50, NOW - 10], 3, TW, False),
              (True, "thermal", 3, TW))
        check("decide_pin: crashes priority over thermal",
              m.decide_pin([NOW - 100, NOW - 50, NOW - 10], NOW, 3, CW,
                           [NOW - 100, NOW - 50, NOW - 10], 3, TW, False),
              (True, "crashes", 3, CW))
        check("decide_pin: pinned -> no retrigger",
              m.decide_pin([NOW - 100, NOW - 50, NOW - 10], NOW, 3, CW, [], 3, TW, True),
              (False, None, 0, 0))

        ev = os.path.join(tmpd, "crashes")
        with open(ev, "w") as f:
            f.write("%d\n%d\ngarbage\n%d\n" % (NOW - 100, NOW - 10, NOW - 900))
        check("read_crash_events: window + garbage skip",
              m.read_crash_events(ev, NOW, CW), [NOW - 100, NOW - 10])
        check("read_crash_events: missing file",
              m.read_crash_events(os.path.join(tmpd, "nope"), NOW, CW), [])

        pf = os.path.join(tmpd, "pin")
        m.write_pin_file(pf, "crashes", 3, CW, NOW, 2)
        check("pin file roundtrip", m.parse_pin_file(pf), (NOW, 2, "crashes"))
        with open(pf, "w") as f:
            f.write("")
        check("pin file empty -> external", m.parse_pin_file(pf), (None, None, "external"))
        check("pin file missing -> external",
              m.parse_pin_file(os.path.join(tmpd, "nope2")), (None, None, "external"))
        with open(pf, "w") as f:
            f.write("not a pin line\n")
        check("pin file garbage -> external", m.parse_pin_file(pf), (None, None, "external"))
        with open(pf, "w") as f:
            f.write("reason=thermal count=3 window=1800 ts=xyz n=bad\n")
        check("pin file partial parse", m.parse_pin_file(pf), (None, None, "thermal"))

        check("pin_log_due: first", m.pin_log_due(NOW, None, 300), True)
        check("pin_log_due: inside interval", m.pin_log_due(NOW, NOW - 100, 300), False)
        check("pin_log_due: boundary", m.pin_log_due(NOW, NOW - 300, 300), True)
    except AttributeError as e:
        ko(pin_desc, "pin functions defined", "AttributeError: %s" % e)
finally:
    shutil.rmtree(tmpd, ignore_errors=True)

print("# pass=%d fail=%d" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
