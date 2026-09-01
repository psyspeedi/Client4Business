#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Диагностика. Запуск: make check
#
# Все сетевые проверки идут ИЗ контейнера OpenClaw — то есть ровно оттуда,
# откуда ходит сам агент, и через те же адреса.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

COMPOSE="docker compose"

hdr() { printf '\n\033[1m%s\033[0m\n' "$*"; }

hdr "1. Контейнеры"
$COMPOSE ps --format 'table   {{.Service}}\t{{.Status}}'

hdr "2. Конфигурация агента"
$COMPOSE run --rm -T --entrypoint node openclaw-cli -e '
const c = require("/home/node/.openclaw/openclaw.json");
const tg = c.channels?.telegram ?? {};
// Секретный префикс реле не показываем: вывод check попадает в скринкаст.
const mask = (v) => v.replace(/\/r\/[A-Za-z0-9_-]{8,}\//, "/r/…/");
const p  = (v, d) => (v ? mask(v) : d);
console.log(`  Bot API      : ${p(tg.apiRoot, "https://api.telegram.org (напрямую)")}`);
console.log(`  OpenRouter   : ${p(c.models?.providers?.openrouter?.baseUrl, "https://openrouter.ai/api/v1 (напрямую)")}`);
console.log(`  модель       : ${p(c.agents?.defaults?.model, "—")}`);
console.log(`  инструменты  : ${p(c.tools?.profile, "—")}`);
console.log(`  кому отвечает: ${p(tg.dmPolicy, "—")}${tg.allowFrom?.length ? ` [${tg.allowFrom.join(", ")}]` : ""}`);
' 2>/dev/null

hdr "3–5. Связь, Telegram, модель"
$COMPOSE exec -T openclaw sh -s <<'INNER'
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; }
inf() { printf '  \033[90mⓘ  %s\033[0m\n' "$*"; }

API_ROOT="${TELEGRAM_API_ROOT:-https://api.telegram.org}"
LLM_BASE="${OPENROUTER_BASE_URL:-https://openrouter.ai/api/v1}"

printf '\n  \033[1mEgress IP\033[0m\n'
ip=$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || echo "n/a")
echo "    адрес контейнера : $ip"
[ "$ip" = "n/a" ] && bad "интернета из контейнера нет" || inf "это адрес самой машины: туннеля на ней нет"

printf '\n  \033[1mTelegram Bot API\033[0m  (%s)\n' "$API_ROOT"
if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
  bad "TELEGRAM_BOT_TOKEN не передан в контейнер"
else
  body=$(curl -s --max-time 20 -w '\n%{http_code}' "${API_ROOT}/bot${TELEGRAM_BOT_TOKEN}/getMe" 2>/dev/null)
  code=$(printf '%s' "$body" | tail -1)
  case "$code" in
    200) ok "getMe → 200, бот @$(printf '%s' "$body" | sed -n 's/.*"username":"\([^"]*\)".*/\1/p')" ;;
    401) bad "getMe → 401: связь есть, токен неверный" ;;
    ""|000) bad "не достучались. Адрес заблокирован? Поднимите реле (relay/) и задайте TELEGRAM_API_ROOT" ;;
    *) bad "getMe → HTTP $code" ;;
  esac
fi

printf '\n  \033[1mOpenRouter\033[0m  (%s)\n' "$LLM_BASE"
if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  bad "OPENROUTER_API_KEY не передан в контейнер"
else
  code=$(curl -s -o /tmp/or.out -w '%{http_code}' --max-time 25 \
    -H "Authorization: Bearer ${OPENROUTER_API_KEY}" "${LLM_BASE}/key" 2>/dev/null)
  case "$code" in
    200)
      ok "ключ действителен"
      inf "$(sed -n 's/.*"label":"\([^"]*\)".*/label: \1/p' /tmp/or.out 2>/dev/null | head -1)"
      inf "$(sed -n 's/.*"limit_remaining":\([^,}]*\).*/остаток лимита: \1/p' /tmp/or.out 2>/dev/null | head -1)"
      ;;
    401) bad "→ 401: связь есть, ключ отвергнут" ;;
    404) bad "→ 404: похоже, OPENROUTER_BASE_URL указывает не на /v1 — проверьте relay/nginx.conf" ;;
    000) bad "не достучались. Адрес заблокирован? Поднимите реле (relay/) и задайте OPENROUTER_BASE_URL" ;;
    *) bad "→ HTTP $code: $(cut -c1-160 /tmp/or.out 2>/dev/null)" ;;
  esac
  rm -f /tmp/or.out
fi
INNER

hdr "6. Дальше"
echo "  make logs    — логи Gateway"
echo "  make status  — состояние каналов"
echo "  make doctor  — самодиагностика OpenClaw"
echo "  make open    — открыть бота для внешней проверки"
