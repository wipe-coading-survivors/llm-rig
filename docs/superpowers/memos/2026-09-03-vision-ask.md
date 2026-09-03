# Мемо: vision-ask.sh — внешнее распознавание картинок (Cloudflare Workers AI)

- Дата: 03.09.2026
- Тип: новый хелпер в `scripts/`; мемо — по домашнему правилу
  (изменения `scripts/` вне плана).

## Что и почему

- Сессия работает на текстовой модели llama-cpp (`qwen3.8-27b-ud`,
  `/v1/models`: `input_modalities: ["text"]`) — картинки «увидеть» не
  может. `scripts/vision-ask.sh` шлёт картинку во внешний vision-сервис
  (Cloudflare Workers AI, free tier — 10 000 neural-кредитов/день) и
  печатает текстовый ответ модели.
- Интерфейс: `vision-ask.sh IMAGE [PROMPT]`. PROMPT по умолчанию —
  «описать + дословно транскрибировать весь видимый текст». Модель —
  `VISION_MODEL` (по умолчанию `@cf/qwen/qwen3.8-27b`; для `@cf/qwen/*`
  добавляется `chat_template_kwargs.enable_thinking=false`), лимит
  ответа — `VISION_MAX_TOKENS` (2000).
- Ключи — хостовый `/etc/llama/cloudflare-ai.env` (600): `CF_ACCOUNT_ID`,
  `CF_API_TOKEN`. Из toolbx скрипт читает
  `/run/host/etc/llama/cloudflare-ai.env` (dual path, паттерн
  `wait-gpu-idle.sh`). CRE не используется — no-cre-hardcode тривиален.
- Токен не попадает в argv (no-sensitive): заголовок `Authorization`
  передаётся curl'у через stdin (`-H @-`).
- **Приватность: содержимое картинки уходит на Cloudflare.** Для
  чувствительных данных — не использовать; альтернатива — локальная
  VL-модель (обоснование выбора сервиса — в отчёте).

## Верификация

- 03.09.2026 (live): тестовая PNG (ImageMagick: заголовок, дата,
  кириллическая строка, красный прямоугольник) → модель вернула весь
  текст дословно (включая кириллицу) и описала фигуру. Повторный прогон
  после правки `-H @-` — OK.
- Изыскания (почему Cloudflare, а не Gemini/HF/локальная VL) —
  `docs/superpowers/reports/2026-09-03-vision-research.md`.
