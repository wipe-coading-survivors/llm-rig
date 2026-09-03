#!/bin/sh
# vision-ask — распознавание картинки через внешний vision-модель
# (Cloudflare Workers AI, бесплатный tier).
#
#   vision-ask IMAGE [PROMPT]
#
# Ключи: /etc/llama/cloudflare-ai.env (CF_ACCOUNT_ID, CF_API_TOKEN);
# из toolbx — /run/host/etc/llama/cloudflare-ai.env. Модель — VISION_MODEL
# (по умолчанию @cf/qwen/qwen3.8-27b), лимит ответа — VISION_MAX_TOKENS
# (2000). ВНИМАНИЕ: содержимое картинки уходит на Cloudflare.

die() {
    echo "vision-ask: $*" >&2
    exit 1
}

command -v jq >/dev/null || die "нужен jq"
command -v curl >/dev/null || die "нужен curl"

[ -n "${1:-}" ] || die "usage: vision-ask IMAGE [PROMPT]"
IMG=$1
shift
PROMPT=${*:-"Describe this image in detail. Transcribe ALL visible text verbatim."}

ENV_FILE=/etc/llama/cloudflare-ai.env
[ -f "$ENV_FILE" ] || ENV_FILE=/run/host/etc/llama/cloudflare-ai.env
[ -f "$ENV_FILE" ] || die "нет файла ключей: /etc/llama/cloudflare-ai.env (хост) или /run/host/etc/llama/cloudflare-ai.env (toolbx)"
. "$ENV_FILE"
[ -n "${CF_ACCOUNT_ID:-}" ] && [ -n "${CF_API_TOKEN:-}" ] || die "CF_ACCOUNT_ID/CF_API_TOKEN пустые в $ENV_FILE"
[ -r "$IMG" ] || die "нечитаемый файл: $IMG"

MODEL=${VISION_MODEL:-@cf/qwen/qwen3.8-27b}
MAX_TOKENS=${VISION_MAX_TOKENS:-2000}
case "$MAX_TOKENS" in (*[!0-9]*|'') die "VISION_MAX_TOKENS должен быть числом: $MAX_TOKENS";; esac

MIME=$(file --mime-type -b "$IMG")
B64=$(base64 -w0 "$IMG") || die "base64: $IMG"

if [ "${MODEL#@cf/qwen/}" != "$MODEL" ]; then
    EXTRA=$(jq -n '{enable_thinking: false}')
else
    EXTRA=null
fi
PAYLOAD=$(jq -n \
    --arg url "data:${MIME};base64,${B64}" \
    --arg prompt "$PROMPT" \
    --argjson max_tokens "$MAX_TOKENS" \
    --argjson extra "$EXTRA" \
    '(if $extra == null then {} else {chat_template_kwargs: $extra} end)
     + {
        messages: [{role: "user", content: [
            {type: "image_url", image_url: {url: $url}},
            {type: "text", text: $prompt}
        ]}],
        max_tokens: $max_tokens
     }') || die "сборка запроса (jq) не удалась"

# Токен не попадает в argv (no-sensitive): заголовок — через stdin.
RESP=$(printf 'Authorization: Bearer %s\n' "$CF_API_TOKEN" | curl -sS --max-time 120 -X POST \
    "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/ai/run/${MODEL}" \
    -H @- \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD") || die "запрос к Cloudflare не удался"

if ! printf '%s' "$RESP" | jq -e '.success == true' >/dev/null 2>&1; then
    MSG=$(printf '%s' "$RESP" | jq -r '.errors[0].message // "неизвестная ошибка"' 2>/dev/null)
    die "API-ошибка: $MSG"
fi

TEXT=$(printf '%s' "$RESP" | jq -r '.result.choices[0].message.content // .result.data // empty')
[ -n "$TEXT" ] || die "пустой ответ модели ($MODEL)"
printf '%s\n' "$TEXT"
