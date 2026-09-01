#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# Headless-бутстрап OpenClaw. Запускается при каждом `up`, идемпотентен:
# повторный прогон ничего не ломает и не перезаписывает конфиг.
#
#   1. права на volume
#   2. проверка связи с Bot API (через реле или напрямую)
#   3. если конфига нет — onboard --non-interactive (провайдер OpenRouter)
#   4. реле: apiRoot для Telegram, baseUrl для OpenRouter
#   5. модель, профиль инструментов, SOUL.md
#   6. Telegram-канал и политика доступа
# ─────────────────────────────────────────────────────────────────────────────
set -eu

STATE_DIR=/home/node/.openclaw
WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-$STATE_DIR/workspace}"
CONFIG_PATH="$STATE_DIR/openclaw.json"
API_ROOT="${TELEGRAM_API_ROOT:-https://api.telegram.org}"

log()  { printf '\033[36m[bootstrap]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[bootstrap] ОШИБКА:\033[0m %s\n' "$*" >&2; exit 1; }

# ── 1. права на volume ──────────────────────────────────────────────────────
if [ "$(id -u)" = "0" ]; then
  log "готовлю $STATE_DIR"
  mkdir -p "$WORKSPACE_DIR" /home/node/.config/openclaw
  chown -R node:node "$STATE_DIR" /home/node/.config/openclaw
  exec su node -s /bin/sh -c "\"$0\" \"\$@\"" -- "$@"
fi

cd /app

run() {
  log "openclaw $*"
  node dist/index.js "$@"
}

[ -n "${TELEGRAM_BOT_TOKEN:-}" ] || die "TELEGRAM_BOT_TOKEN не задан (см. .env)"
[ -n "${OPENROUTER_API_KEY:-}" ] || die "OPENROUTER_API_KEY не задан (см. .env)"

# ── 2. связь с Bot API ──────────────────────────────────────────────────────
# Токен в проверку не подставляем, чтобы он не оседал в логах: до корня
# Bot API достаточно достучаться без него — любой ответ означает, что
# соединение установлено, а верность токена покажет `make check`.
log "проверяю Bot API: $API_ROOT"
# При сетевой ошибке curl и сам печатает 000, но выходит с ненулевым кодом —
# присваивание ниже приводит оба случая к одному значению.
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$API_ROOT" 2>/dev/null) || code=000
case "$code" in
  000)
    die "нет связи с $API_ROOT.
       Если адрес заблокирован — поднимите реле (см. relay/) и задайте
       TELEGRAM_API_ROOT в .env, либо укажите HTTPS_PROXY."
    ;;
  *) log "Bot API отвечает (HTTP $code)" ;;
esac

# ── 3. onboarding ───────────────────────────────────────────────────────────
if [ -f "$CONFIG_PATH" ]; then
  log "конфиг уже существует, onboarding пропускаю ($CONFIG_PATH)"
else
  log "первый запуск: неинтерактивный onboarding, провайдер OpenRouter"
  # --secret-input-mode ref → в openclaw.json пишется ссылка на переменную
  #   окружения, сам ключ остаётся только в .env.
  # --skip-health → провайдера не дёргаем до того, как задан baseUrl реле.
  run onboard \
    --non-interactive \
    --accept-risk \
    --skip-health \
    --mode local \
    --agent-name main \
    --auth-choice openrouter-api-key \
    --secret-input-mode ref \
    --gateway-auth token \
    --gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN \
    --skip-channels \
    --no-install-daemon
fi

# ── 4. реле ─────────────────────────────────────────────────────────────────
# Нативный провайдер openrouter сохраняется целиком (каталог моделей, цены,
# заголовки) — подменяется только базовый адрес.
if [ -n "${OPENROUTER_BASE_URL:-}" ]; then
  log "LLM через реле → $OPENROUTER_BASE_URL"
  run config set models.providers.openrouter.baseUrl "$OPENROUTER_BASE_URL"
else
  log "LLM напрямую (openrouter.ai)"
fi

# ── 5. модель, инструменты, SOUL.md ─────────────────────────────────────────
if [ -n "${LLM_MODEL:-}" ]; then
  case "$LLM_MODEL" in
    */*) MODEL_REF="$LLM_MODEL" ;;
    *)   MODEL_REF="openrouter/$LLM_MODEL" ;;
  esac
  log "модель агента → $MODEL_REF"
  run config set agents.defaults.model "$MODEL_REF"
fi

# minimal по умолчанию: бот открыт для проверяющих, а в окружении процесса
# лежат токен бота и ключ провайдера. С профилем coding агент имеет exec и
# по первой же просьбе выдаст их содержимое.
log "профиль инструментов → ${TOOLS_PROFILE:-minimal}"
run config set tools.profile "${TOOLS_PROFILE:-minimal}"

# SOUL.md — персональная инструкция агента; лежит в репозитории и
# перезаписывается при каждом старте, чтобы правки шли через git.
if [ -f /bootstrap/SOUL.md ]; then
  log "ставлю SOUL.md → $WORKSPACE_DIR/SOUL.md"
  mkdir -p "$WORKSPACE_DIR"
  cp /bootstrap/SOUL.md "$WORKSPACE_DIR/SOUL.md"
fi


# ── 6. Telegram ─────────────────────────────────────────────────────────────
# --use-env: токен не копируется в openclaw.json, читается из окружения.
if node dist/index.js config get channels.telegram.enabled 2>/dev/null | grep -q true; then
  log "Telegram-канал уже настроен"
else
  run channels add --channel telegram --use-env
fi

if [ -n "${TELEGRAM_API_ROOT:-}" ]; then
  log "Bot API через реле → $TELEGRAM_API_ROOT"
  run config set channels.telegram.apiRoot "$TELEGRAM_API_ROOT"
fi

DM_POLICY="${TELEGRAM_DM_POLICY:-allowlist}"
case "$DM_POLICY" in
  allowlist)
    [ -n "${TELEGRAM_OWNER_ID:-}" ] || die "TELEGRAM_DM_POLICY=allowlist требует TELEGRAM_OWNER_ID.
       Свой numeric id — у @userinfobot. Чтобы открыть бота всем (например,
       на время проверки), поставьте TELEGRAM_DM_POLICY=open."
    log "личные сообщения: allowlist [$TELEGRAM_OWNER_ID]"
    run config set --batch-json "[
      {\"path\":\"channels.telegram.dmPolicy\",\"value\":\"allowlist\"},
      {\"path\":\"channels.telegram.allowFrom\",\"value\":[\"$TELEGRAM_OWNER_ID\"]}
    ]"
    ;;
  open)
    # Одного dmPolicy=open мало: при пустом allowFrom Gateway молча отбрасывает
    # все личные сообщения. Пускающий всех список — это "*".
    log "личные сообщения: open — отвечает любому, кто напишет"
    run config set --batch-json '[
      {"path":"channels.telegram.dmPolicy","value":"open"},
      {"path":"channels.telegram.allowFrom","value":["*"]}
    ]'
    ;;
  pairing)
    log "личные сообщения: pairing — первый диалог подтверждается через make pair"
    run config set channels.telegram.dmPolicy pairing
    ;;
  *) die "TELEGRAM_DM_POLICY=$DM_POLICY: допустимы allowlist | open | pairing" ;;
esac

# Владелец сохраняется отдельно от политики доступа: служебные команды
# остаются только у него, даже когда бот открыт всем.
if [ -n "${TELEGRAM_OWNER_ID:-}" ]; then
  run config set --batch-json "[{\"path\":\"commands.ownerAllowFrom\",\"value\":[\"telegram:$TELEGRAM_OWNER_ID\"]}]"
fi

# Стенд рассчитан на сеть, где часть адресов недоступна: каждое лишнее
# исходящее соединение там превращается в таймаут в логах.
#   telemetry            — обращения к telemetry.openclaw.ai;
#   hooks.session-memory — синхронизация памяти сессий, которая требует
#                          отдельного ключа openai и без него всё равно
#                          падает («No API key found for provider "openai"»).
# Обе настройки возвращаются одной командой, если понадобятся:
#   make cli ARGS="config set telemetry.enabled true"
run config set --batch-json '[
  {"path":"telemetry.enabled","value":false},
  {"path":"hooks.internal.entries.session-memory.enabled","value":false}
]'

# Gateway на старте проверяет стоковые плагины и отказывается сообщать о
# готовности, пока `perplexity` не получит согласие на свои capability:
#   «Plugin "perplexity" requires capability consent … refusing to report
#    the gateway ready».
# Мы им не пользуемся — выключаем явно, вместо того чтобы выдавать согласие
# на ненужные права. Команда идёт последней: в сборках, где плагин не
# установлен, она добавляет предупреждение ко всем последующим вызовам.
run config set plugins.entries.perplexity.enabled false

run config set --batch-json '[
  {"path":"gateway.mode","value":"local"},
  {"path":"gateway.bind","value":"lan"},
  {"path":"gateway.controlUi.allowedOrigins","value":["http://localhost:18789","http://127.0.0.1:18789"]}
]'

log "готово. Gateway можно запускать."
