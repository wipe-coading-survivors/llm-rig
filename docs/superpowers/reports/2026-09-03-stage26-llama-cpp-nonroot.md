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
- 19:29:43 — потолок привёл к **cgroup-OOM-киллу инстанса**
  (kernel-лог: `llama-server invoked oom-killer`,
  `constraint=CONSTRAINT_MEMCG`, `Killed process 1682351
  (llama-server)`, anon-rss 117.6 GiB, uid 1001001) — инстанс был
  в полёте большого префилла (task 40041, контекст 123k). Контейнер
  выжил: роутер (pid 1) — `instance name=default exited with status
  1` + авто-респаун инстанса (lazy reload, порт 34625); watcher
  молчал (крэш-паттерна нет, контейнер жив). В логах llama «креша»
  нет — причина только в kernel-логе.
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

## 9. Ночной прогон sampler (16:55 → 04.09 00:45 MSK, 48/48 сэмплов)

Файл: `/tmp/llm-rig/stage26/mem-samples.tsv` (шаг 10 мин, без
пропусков; самозавершение штатное).

- Хвост 120g: потолок достигнут к 18:55 (128.76 GiB; file-кэш
  29.9 → 4.0 GB), 19:29:43 — OOM-килл инстанса (§8); контейнер НЕ
  перезапускался — роутер респаунил инстанс (сэмпл 19:35 — та же
  120g-оболочка со свежей загрузкой модели, file-кэш 27.8 GiB).
- 160g (с 19:45): 4.4 → пик **157.4 GB (23:35; 91.6% лимита
  171.8 GB)**; два reclaim-dip (22:45: 144 → 118.5; 23:45:
  157.4 → 120.9 GB); ночной коридор 117–157 GB. OOM не
  зафиксировано.
- Провал 00:45 до ~12 GB (cgroup; anon 2.4 GiB) — idle: KV-кэш
  cache-ram освобождён, не рестарт (контейнер тот же, старт
  19:45:24). К утру (01:26) — снова 124.7 GB (anon 113.9 GiB).
- Вывод: 160g держит реальную нагрузку 8+ ч без OOM; запас до
  пика ~14 GB. При дальнейшем росте (большие контексты, больше
  сессий) — поднимать `LLAMA_MEM` (зона оператора, спека).
  (Постскриптум 06.09: «8+ ч без OOM» — удачное окно; на
  накопленном трафике пул заполнился до 128 GiB и OOM пошли
  серийно — §10.)

## 10. OOM при 160g (04.09–06.09) и решение 192g + пул 96 GiB

### Факты (kernel-лог + unit-лог)

6 cgroup-OOM-киллов инстанса с момента 160g: 04.09 ×2,
05.09 ×2 (11:35, 21:21), 06.09 ×2 (12:27:51, 13:48:51).
Контейнер (роутер pid 1) ни разу не перезапускался
(`0159dfaccff0`, старт 03.09 19:45): OOM киллит инстанс
(крупнейший процесс memcg), роутер его респаунит (lazy
reload). Watcher не срабатывал: zombie-сигнатуры в логе нет
(только `instance name=default exited with status 1`).

Состав килла (13:48:51): `usage = limit = 160 GiB` ровно,
`failcnt 56430`; anon 158.0 GiB:

| компонент | размер |
|---|---|
| cache-ram 131072 MiB (заполнен) | 128 GiB (77%) |
| KV двух слотов (137k + 42.6k) + scratch двойного префилла + SWA-checkpoints | ~28 GiB |
| shmem + file + kernel/pgtables | ~4.7 GiB |

Триггер (логи обоих окон 06.09): две крупные сессии,
одновременные префиллы при полном пуле — транзиентные
аллокации перелезают лимит.

KV-ставка (из состава килла): ~122 MiB/1k токенов (q8_0) →
215k-слот ≈ 25 GiB. Оценка §8 «KV 2×215k ~20» занижена в
2.5 раза; структурный потолок конфига: 128 (пул) + ~55
(2×215k) + ~5 ≈ **188 GiB > 160g** — steady-state без запаса.

### Цена OOM (измерено, 13:48)

килл 13:48:51 → respawn 13:48:59 → загрузка модели ~1 мин →
полные ре-префиллы обеих сессий (43.6k — 285 s; 137.4k —
243 s) → **~6 мин деградации**; клиентам 500 `request
cancelled while waiting`.

### Пул: квантование по сессиям и тиры

Пул `--cache-ram` — LRU-кольцо снапшотов контекстов слотов
(`prompt_save`/`prompt_load`, restore без ре-префилла).
Полезное содержимое = сумма актуальных снапшотов живых
сессий; старые версии растущего (append-only) контекста — его
префиксы, не нужны. Пул меньше суммы актуальных снапшотов →
вытеснение → ре-префилл; больше → кольцо крутит старые
версии, RAM закоммичена без пользы. «2.5 сессии» как тир
не существует. Запас сверх строгого N снапшотов = 1–2
снапшота (write-then-evict транзиент при save + churn-буфер).

| тир | pool | + live 2×215k + прочее | лимит |
|---|---|---|---|
| T1 (1 юзер) | 32 GiB | ~62 GiB | 80g |
| T2 (2 юзера) | 64 GiB | ~120 GiB | 160g |
| T3 (3-я сессия рабочая) | 96 GiB | ~152 GiB | 192g |

Текущая связка 128-пул + 160g = пул тира 3 при лимите тира 2
— структурно битая (188 > 160), и есть.

### Решение (06.09): `LLAMA_MEM=192g` + `cache-ram=98304` (T3)

- хостовый sysconfig `LLAMA_MEM=160g → 192g` — вручную
  (`sysconfig-gen.sh`: значение файла сильнее `--default`);
- live ini `/etc/llama/llama.ini`: `cache-ram = 131072 →
  98304` (бэкап `.ini-6`);
- max ~152 GiB против лимита 192 → запас ~40 GiB;
- репо: Makefile `--default LLAMA_MEM=120g → 192g`,
  зеркало `debug/llama-run.sh` `-m 192g`, пины
  `test-makefile-graph.sh` / `test-debug-scripts.sh`;
- safe-restart по `make llama-cpp-restart` (SAME_HOST).
