# Мемо: llama-cpp память — `LLAMA_MEM=192g` + `cache-ram=98304` (тир T3)

- Дата: 06.09.2026
- Тип: live-конфиг + Makefile-дефолт, вне плана/спеки (реакция на
  серийные OOM). Полное обоснование —
  `docs/superpowers/reports/2026-09-03-stage26-llama-cpp-nonroot.md`
  §10; отдельной спеки/плана памяти в репо нет (в Этапе 26 — только
  «LLAMA_MEM — зона оператора», преистория — в архивном репо),
  поэтому мемо + §10 отчёта — уровень документации.

## Что и почему

- 6 cgroup-OOM-киллов инстанса при `LLAMA_MEM=160g` + пул
  `cache-ram=131072` (128 GiB) за 04.09–06.09. Контейнер (роутер)
  во всех случаях выживал и респаунил инстанс; watcher не
  срабатывал (zombie-сигнатуры в логе нет). Цена OOM ~6 мин
  деградации (загрузка модели + полные ре-префиллы сессий).
- Состав килла: `usage = limit = 160 GiB`; anon 158 GiB =
  **пул 128 GiB (77% лимита, заполнен)** + ~28 GiB (KV 2 живых
  слотов + scratch + checkpoint'и) + shmem/file/kernel ~5 GiB.
- KV-ставка ~122 MiB/1k токенов (q8_0) → 215k-слот ≈ 25 GiB;
  оценка Этапа 26 «KV 2×215k ~20» занижена в 2.5×. Структурный
  потолок конфига ≈ 188 GiB > 160g — steady-state без запаса.
- Пул квантован по сессиям (LRU-кольцо снапшотов; полезное =
  сумма актуальных снапшотов, «2.5 сессии» не существует):
  T1 32 GiB → лимит 80g; T2 64 GiB → 160g; **T3 (3-я параллельная
  сессия — рабочий случай, решение оператора) 96 GiB → 192g**.
- Текущая связка 128-пул + 160g = пул тира 3 при лимите тира 2 —
  структурно битая.

## Изменения

- Репо (main, `8621318`):
  - `Makefile`: `--default LLAMA_MEM=120g → 192g` (дефолт догоняет
    live: rewriter `sysconfig-gen.sh` значение файла считает
    сильнее `--default`, дефолт был отсталым);
  - `debug/llama-run.sh` (зеркало юнита для manual-fallback):
    `-m 120g → 192g`;
  - пины: `scripts/test-makefile-graph.sh`,
    `scripts/test-debug-scripts.sh`;
  - `LIVE-SERVER.md` («Топология» + «Числа» 06.09), отчёт Этапа 26
    §10 (анализ + тиры + решение).
- Host one-shot (вне репо):
  - `/etc/sysconfig/llama-cpp`: `LLAMA_MEM=160g → 192g` (вручную);
  - `/etc/llama/llama.ini`: `cache-ram = 131072 → 98304` (бэкап
    `llama.ini-6`, комментарий с причиной в файле).
- Safe-restart `make llama-cpp-restart MODE=restart IDLE_TIMEOUT=300`
  (06.09 15:10:13–15:10:58): `done rc=0`, wait-ready 28 s (тёплый
  NFS), verify 200; SAME_HOST-сессия переживает (ре-префилл).

## Верификация

- `memory.max = 192.0 GiB` (206.2 GB, cgroup); юнит active.
- Пресет `/v1/models`: `cache-ram = 98304`.
- Тесты: `test-makefile-graph` 357/357, `test-debug-scripts`
  37/37.
- Ожидаемый max-футпринт: 96 (пул) + ~51 (live 2×215k) + ~5 ≈
  152 GiB против лимита 192 → запас ~40 GiB. Контроль:
  `memory.current` в cgroup (порог тревоги ~170 GiB); при OOM —
  kernel-лог (`journalctl -k | grep -E 'oom-killer|Killed process'`).
