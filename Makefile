SHELL := /bin/bash
COMPOSE := docker compose

.DEFAULT_GOAL := help

help: ## показать этот список
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

init: ## создать .env из шаблона и сгенерировать токен Gateway
	@test ! -f .env || { echo ".env уже существует — не перезаписываю"; exit 1; }
	@cp .env.example .env
	@token=$$(openssl rand -hex 32); \
		sed -i.bak "s|^OPENCLAW_GATEWAY_TOKEN=.*|OPENCLAW_GATEWAY_TOKEN=$$token|" .env && rm -f .env.bak
	@echo "Создан .env. Заполните:"
	@echo "  TELEGRAM_BOT_TOKEN  — от @BotFather"
	@echo "  TELEGRAM_OWNER_ID   — ваш numeric id (@userinfobot)"
	@echo "  OPENROUTER_API_KEY  — с openrouter.ai/keys"
	@echo "Если api.telegram.org или openrouter.ai недоступны — поднимите"
	@echo "реле (relay/) и задайте TELEGRAM_API_ROOT / OPENROUTER_BASE_URL."
	@echo "Затем: make up"

up: ## поднять стек
	$(COMPOSE) up -d
	@port=$$(grep -E '^OPENCLAW_GATEWAY_PORT=' .env | cut -d= -f2 | tr -d ' '); \
		echo; echo "Control UI: http://127.0.0.1:$${port:-18789}/  (токен — OPENCLAW_GATEWAY_TOKEN из .env)"

down: ## остановить стек
	$(COMPOSE) down

restart: ## перечитать .env и пересоздать контейнеры
	$(COMPOSE) up -d --force-recreate

relay-host: ## собрать конфиги реле: make relay-host HOST=relay.example.com [PORT=8444] [PREFIX=...]
	@bash scripts/relay-config.sh "$(HOST)" "$(or $(PORT),443)" "$(PREFIX)"

check: ## диагностика: связь, Telegram, модель, egress-IP
	@bash scripts/check.sh

open: ## открыть бота для всех (на время внешней проверки)
	@$(COMPOSE) run --rm openclaw-cli config set --batch-json \
		'[{"path":"channels.telegram.dmPolicy","value":"open"},{"path":"channels.telegram.allowFrom","value":["*"]}]'
	@$(COMPOSE) restart openclaw
	@echo "Бот отвечает всем. Вернуть: make lock"

lock: ## закрыть бота обратно на владельца
	@id=$$(grep -E '^TELEGRAM_OWNER_ID=' .env | cut -d= -f2 | tr -d ' '); \
		test -n "$$id" || { echo "TELEGRAM_OWNER_ID пуст в .env"; exit 1; }; \
		$(COMPOSE) run --rm openclaw-cli config set --batch-json \
			"[{\"path\":\"channels.telegram.dmPolicy\",\"value\":\"allowlist\"},{\"path\":\"channels.telegram.allowFrom\",\"value\":[\"$$id\"]}]"
	@$(COMPOSE) restart openclaw
	@echo "Бот отвечает только владельцу."

soul: ## перечитать openclaw/SOUL.md без пересоздания стека
	@$(COMPOSE) cp openclaw/SOUL.md openclaw:/home/node/.openclaw/workspace/SOUL.md
	@$(COMPOSE) restart openclaw
	@echo "SOUL.md обновлён."

logs: ## логи Gateway
	$(COMPOSE) logs -f --tail=200 openclaw

status: ## состояние контейнеров и каналов
	@$(COMPOSE) ps
	@echo
	@$(COMPOSE) run --rm openclaw-cli channels status --probe || true

pair: ## подтвердить pairing-запрос из Telegram
	@$(COMPOSE) run --rm openclaw-cli pairing list telegram
	@read -rp "код для подтверждения: " code; \
		$(COMPOSE) run --rm openclaw-cli pairing approve telegram "$$code"

cli: ## произвольная команда CLI: make cli ARGS="config get channels.telegram"
	@$(COMPOSE) run --rm openclaw-cli $(ARGS)

doctor: ## самодиагностика OpenClaw
	@$(COMPOSE) run --rm openclaw-cli doctor

config: ## показать openclaw.json
	@$(COMPOSE) run --rm --entrypoint cat openclaw-cli /home/node/.openclaw/openclaw.json

clean: ## снести стек вместе с состоянием (необратимо)
	$(COMPOSE) down -v

.PHONY: help init up down restart relay-host check open lock soul logs status pair cli doctor config clean
