# Этап 26 — live-окно: non-root контейнер `llama-cpp`

Дата: 2026-09-03. Ветка: `stage26-llama-cpp-nonroot`. Протокол: спека
`docs/superpowers/specs/2026-09-03-llama-cpp-nonroot-design.md`, секция
«Live-окно» + план, Task 5. Операции — `LIVE-SERVER.md`.

## 1. Pre-снимки (16:42 MSK / 13:42 UTC)

Снимки: `/tmp/llm-rig/stage26/` (`pre-inspect.json`, `pre-sysconfig`,
`pre-ini`, `pre-keys-mode`, `pre-stats.txt`).

- Старый контейнер `f5e0246cecc4`: root, `--privileged`,
  `--shm-size=64g`, mount `/etc/llama:/root/llama:ro`;
  MEM 115.1GB / 270.3GB (42.57%), CPU time 4h57m.
- `/etc/sysconfig/llama-cpp`: `LLAMA_SHM_SIZE=64g`; ключей
  `LLAMA_UID`/`LLAMA_MEM` нет.
- `/etc/llama/llama-cpp-keys.txt`: mode `600 root:root`.
- `/etc/llama/llama.ini`: `api-key-file = /root/llama/llama-cpp-keys.txt`.
- git: дерево чистое, HEAD=6300e0d (Tasks 1–4: юнит, Makefile,
  debug-скрипты, LIVE-SERVER).
- `MODE=check` (16:42:58): `same-host yes`, `unit=active`,
  `slots busy=0`, `model loaded`, `done rc=0`.

## 2. Deploy: `make systemd` (16:43)

- Юнит на хосте == юнит репо (non-root) — `diff` пуст, `UNIT-OK`.
- `sysconfig-gen`: добавлены `LLAMA_UID=1001001`, `LLAMA_MEM=120g`;
  `LLAMA_SHM_SIZE` остался `64g` (существующее значение не
  переопределяется — by design, one-shot ниже).
- keys: `600 → 640` (guarded idempotent-шаг сработал, файл есть).

## 3. Host-правки (one-shot, 16:43)

- `sed`: sysconfig `LLAMA_SHM_SIZE=64g → 1g`.
- `sed`: ini `api-key-file → /llama/llama-cpp-keys.txt`.
- Сверка: `LLAMA_SHM_SIZE=1g`;
  `api-key-file = /llama/llama-cpp-keys.txt`.

## 4. Рестарт (16:44:03) — `MODE=restart`

SAME_HOST=yes; сессия не прервалась: в момент `wait-idle` слоты были
idle (нет in-flight-генерации), stop→ready 106 s, opencode пережил
паузу сервера.

```
2026-09-03T16:44:03 start pid=1681297 mode=restart url=http://<LLAMA_HOST>:8080 model=default
2026-09-03T16:44:03 preflight ok unit=active
2026-09-03T16:44:03 same-host yes
2026-09-03T16:44:03 wait-idle timeout=30s model=default
2026-09-03T16:44:03 wait-idle idle
2026-09-03T16:44:03 restarting via unit llama-cpp
2026-09-03T16:45:49 wait-ready timeout=600s model=default
2026-09-03T16:47:18 wait-ready model loaded
2026-09-03T16:47:18 verifying model=default
2026-09-03T16:47:20 verifying 200 OK
2026-09-03T16:47:20 done rc=0
```

- t0→t1 (старт → первый `/health` ok): **106 s** (без stop-hang: слоты
  idle, known-issue stop/restart-hang не воспроизведён).
- t1→t2 (→ модель `loaded`): **89 s** (cold NFS, модель 30 GB; тёплый
  case Этапа 25 — 21 s, cold-оценка 70–80 s — в коридоре).
- t2 verify (POST keyed, `max_tokens=8`): **2 s**, 200 OK.
- Итого: ~3.3 мин.

## 5. Приёмка (16:50 MSK)

| Пункт | Ожидание | Факт |
|---|---|---|
| `exec llama-cpp id` | `uid=1001001 gid=0` | `uid=1001001(1001001) gid=0(root) группы=0(root)` |
| `/dev/shm` | 1.0G | `1,0G`, занято **185M (18%)** — как до этапа |
| memlock (контейнер `/proc/1/limits`) | unlimited | `Max locked memory unlimited unlimited` |
| `/v1/models` | `loaded` | `loaded` |
| VRAM | модель на 5×GPU | 5×3060: 11.5–12.0 / 12.3 GB каждая, util активный |
| keyed-эндпоинты | POST 200 | verify в потоке рестарта: 200 OK |
| `nvidia-caps` | — | **0 open fds** у инстанса — CUDA-контекст создаётся без caps (R1 закрыт, fallback не потребовался) |
| OOM / seccomp / apparmor | — | нет (R2 закрыт, fallback не потребовался) |
| memory limit | 120 GiB | `memory.max = 128849018880` (120 GiB) |

## 6. Память: baseline + динамика (16:52–18:15 MSK)

Метрики (уточнение F16): `podman stats` ≈ anon+shmem (file-кэш не
входит); cgroup `memory.current` = anon+file+shmem.

- `file` = **29.9 GiB, константа** — page cache модели (NFS),
  charged в cgroup; в `podman stats` не виден.
- `shmem` = **2.0 GiB, константа**.
- `anon` растёт скачками с сессионным трафиком (cache-ram/KV) и
  выходит в плато — паттерн F8:

| Время (MSK) | `podman stats` | cg `memory.current` | anon |
|---|---|---|---|
| 16:52 (baseline) | 7.94 GB | 35.7 GiB | 5.3 GiB |
| 16:55 | 13.25 GB | 41.0 GiB | 10.3 GiB |
| 17:05 | 13.25 GB | 41.0 GiB | 10.3 GiB |
| 17:15 | 25.64 GB | 49.7 GiB | 21.8 GiB |
| 17:25 | 26.93 GB | 51.0 GiB | 23.0 GiB |
| 17:35–18:15 | 26.93 GB | ~51.0 GiB | 23.0–23.1 GiB (плато, +0.3 GiB/40 мин) |

- Скачок 17:05→17:15 (+12.4 GiB) — prefill длинного контекста
  сессии; далее плато (второй пользователь неактивен, трафик —
  только сессия координатора).
- Пик окна: **51.0 GiB = 42% лимита 120 GiB**.
- OOM-точек нет. `LLAMA_MEM=120g` — стартовое значение с запасом
  >2× над текущим steady-state; при OOM оператор поднимает в
  sysconfig (решение 03.09, зона оператора; протокол OOM — спека
  R3/R7).
- Фоновый sampler (10 мин × 8 ч, самозавершение) продолжил съёмку в
  `/tmp/llm-rig/stage26/mem-samples.tsv` (pid в `mem-sample.pid`) —
  для наблюдения за ростом с накопленным трафиком после окна.

## 7. Итог / приёмка

Все пункты плана Step 5 зелёные: non-root (`1001001:0`), без
`--privileged`, memlock unlimited, shm 1g (факт 185M), `/llama`
mount+preset, keyed-эндпоинты, GPU/model-load, лимит 120g, рестарт
без потерь (3.3 мин, verify 200). Fallback'и R1/R2 не использовались.
Этап закрыт.

## 8. Post-окно (16:55–19:49 MSK)

- Динамика с активной сессией (sampler, 10 мин): 13.25 → 26.93 GB
  (плато в idle) → 35.8 → 44.5 → 80.2 → 102.5 GB; к 18:55 cgroup
  прижат к потолку 120g (128.847/128.849 GiB), file-кэш модели
  рекалмится 29.9 → 7.8 GiB как кушон, anon → 111.9 GiB (pool
  cache-ram + KV живых слотов). OOM нет — но потолок достигнут.
- `erasing old context checkpoint` в логах (23×, слот 1, ~570 MiB
  каждое) — штатная ротация SWA-checkpoints (`--swa-checkpoints 64`),
  не признак давления; evictions pool'а нет.
- `llama-server --metrics` (роутер, keyed): только токены/тайминги/
  spec-decode — память в Prometheus не отдаётся.
- Решение оператора (19:40): `LLAMA_MEM 120g → 160g` (worst case:
  pool 128 + KV 2×215k ~20 + shmem 2 ≈ 150; модель при mlock на
  практике reclaimable — 22GB-кушон — но запас на KV обязателен).
- Рестарт 19:43:41: t0→t1 102 s, t1→t2 24 s (тёплый NFS), verify
  2 s, `done rc=0`. Приёмка: `uid=1001001 gid=0`, `memory.max =
  171798691840` (160 GiB), 19.5/171.8 GB после старта, модель
  loaded, keyed 200.
