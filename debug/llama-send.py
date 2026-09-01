#!/usr/bin/env python3
import json, os, sys, random, urllib.request, urllib.error, time

KEYFILE = "/run/host/etc/llama/llama-cpp-keys.txt" if os.path.isfile("/run/.containerenv") else "/etc/llama/llama-cpp-keys.txt"
WORDS = ["alpha","bravo","charlie","delta","echo","foxtrot","golf","hotel","india","juliet","kilo","lima","mike","november","oscar","papa","quebec","romeo","sierra","tango"]

def gen(seed, tok):
    rnd = random.Random(seed)
    parts, c = [], 0
    while c < int(tok * 1.565):
        w = f"{rnd.choice(WORDS)}-{rnd.randint(0,999999)}"
        parts.append(w)
        c += len(w) + 1
    return " ".join(parts)

# usage: llama-send.py BASE SEED BASE_TOK MAXTOK SLOT [EXTRA_SEED EXTRA_TOK]
# SLOT: -1 = auto, 0..N-1 = id_slot. EXTRA: доп. хвост (инкрементальный дельта).
base, seed, base_tok, maxtok, slot = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
extra_seed = int(sys.argv[6]) if len(sys.argv) > 6 else -1
extra_tok = int(sys.argv[7]) if len(sys.argv) > 7 else 0
key = open(KEYFILE).read().splitlines()[3].strip()

prompt = gen(seed, base_tok)
if extra_tok > 0:
    prompt += " " + gen(extra_seed, extra_tok)

body = {"model": "default", "prompt": prompt, "max_tokens": maxtok,
        "temperature": 0, "stream": False}
if slot >= 0:
    body["id_slot"] = slot
req = urllib.request.Request(base + "/v1/completions", data=json.dumps(body).encode(),
    headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
t0 = time.time()
try:
    d = json.loads(urllib.request.urlopen(req, timeout=3600).read())
    u = d.get("usage", {})
    cached = u.get("prompt_tokens_details", {}).get("cached_tokens")
    print(f"ok prompt={u.get('prompt_tokens')} cached={cached} gen={u.get('completion_tokens')} {time.time()-t0:.0f}s")
except urllib.error.HTTPError as e:
    print(f"err http{e.code} {e.read().decode()[:300]}")
    sys.exit(2)
except Exception as e:
    print(f"err {type(e).__name__}: {e}")
    sys.exit(2)
