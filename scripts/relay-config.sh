#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Сборка конфигов реле из шаблонов.
#
#   scripts/relay-config.sh HOST [PORT] [PREFIX]
#
# Домен, порт и секретный префикс подставляются в relay/*.template, результат
# кладётся рядом (relay/nginx.conf, relay/Caddyfile) и в .env. Эти файлы
# в .gitignore: в репозитории живут только шаблоны, реквизиты — локально.
#
# Префикс переиспользуется из .env, если он там уже есть, иначе генерируется.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

HOST="${1:-}"
PORT="${2:-443}"
PREFIX="${3:-}"

[ -n "$HOST" ] || { echo "укажите домен: scripts/relay-config.sh relay.example.com [порт] [префикс]" >&2; exit 1; }

# Порт в URL пишется, только если он нестандартный.
if [ "$PORT" = "443" ]; then ORIGIN="$HOST"; else ORIGIN="$HOST:$PORT"; fi

if [ -z "$PREFIX" ] && [ -f .env ]; then
  PREFIX=$(grep -oE '/r/[A-Za-z0-9_-]+/' .env 2>/dev/null | head -1 | sed 's|^/r/||; s|/$||' || true)
fi
if [ -z "$PREFIX" ]; then
  PREFIX=$(openssl rand -hex 12)
  echo "  сгенерирован новый префикс"
fi

for tpl in relay/*.template; do
  out="${tpl%.template}"
  sed -e "s|@@HOST@@|$HOST|g" -e "s|@@PORT@@|$PORT|g" \
      -e "s|@@ORIGIN@@|$ORIGIN|g" -e "s|@@PREFIX@@|$PREFIX|g" "$tpl" > "$out"
  echo "  собран $out"
done

TG_ROOT="https://$ORIGIN/r/$PREFIX/tg"
OR_BASE="https://$ORIGIN/r/$PREFIX/or/v1"

if [ -f .env ]; then
  sed -i "s|^TELEGRAM_API_ROOT=.*|TELEGRAM_API_ROOT=$TG_ROOT|" .env
  sed -i "s|^OPENROUTER_BASE_URL=.*|OPENROUTER_BASE_URL=$OR_BASE|" .env
  echo "  .env обновлён"
else
  echo "  .env ещё нет — создайте через make init и повторите"
fi

cat <<EOF

  Реле:     https://$ORIGIN/
  Telegram: $TG_ROOT
  LLM:      $OR_BASE

  Разложите relay/nginx.conf (или relay/Caddyfile) на сервер, затем: make restart
EOF
