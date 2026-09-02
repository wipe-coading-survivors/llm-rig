# Мемо: wait-gpu-idle.sh — ожидание GPU-idle по lact-autoswitch

- Дата: 02.09.2026
- Тип: новый хелпер в `scripts/` (добавлен в ходе верификации cache-ram,
  TODO 23); мемо — по домашнему правилу (изменения `scripts/` вне плана).

## Что и почему

- `scripts/wait-gpu-idle.sh` — ожидание **подтверждённого** GPU-idle по
  демону `lact-autoswitch`: поле 2 последней строки
  `/run/lact-autoswitch/history.log` == `I`. Демон переводит профиль в
  Idle после TIME_IDLE секунд без запросов, поэтому `I` — уже
  подтверждённый простой (не просто отсутствие нагрузки в момент
  выборки).
- Интерфейс: `--status` → rc 0 = idle, 1 = busy; `[TIMEOUT]` (сек,
  по умолчанию 900) → rc 0 = idle, 124 = timeout, 2 = нет лога /
  неверный аргумент.
- `WAIT_GPU_IDLE_HIST` переопределяет путь к history (hermetic-тесты).
- Два пути к логу: `/run/host/run/lact-autoswitch/history.log` (toolbx)
  и `/run/lact-autoswitch/history.log` (хост) — скрипт работает в обеих
  средах. CRE-инструменты (podman/podman-remote) не используются —
  no-cre-hardcode выполняется тривиально.

## Отношение к llama-cpp-restart.sh

- `wait_idle()` в `llama-cpp-restart.sh` — слотовый (curl `/slots`,
  нет `is_processing`): «в роутере нет in-flight-запросов».
- `wait-gpu-idle.sh` — демонический: «GPU-профиль в подтверждённом
  idle» (учитывает гистерезис TIME_IDLE).
- Взаимодополняют друг друга; в рестартах 02.09.2026 слотового
  ожидания хватило (idle сразу). Хелпер — для сценариев, где нужен
  подтверждённый статус демона (ручные рестарты, VRAM-чувствительные
  операции).

## Верификация

- 02.09.2026 (live): `--status` верно сообщает idle/busy; ожидание с
  коротким таймаутом → rc 124; `WAIT_GPU_IDLE_HIST` + фейковый лог —
  оба состояния и timeout.
