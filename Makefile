.PHONY: help \
        up down restart logs ps \
        iex shell psql \
        migrate reset-db seed \
        test test-watch format credo \
        ni nr build build-back upload upload-front upload-back deploy \
        a b c

VERSION = $(shell git --no-pager describe --always --dirty)

# Compose v2 (docker compose). Override with `make COMPOSE="docker-compose" ...`
# if you're stuck on v1.
COMPOSE ?= docker compose
EXEC    := $(COMPOSE) exec -u rc rc
EXEC_T  := $(COMPOSE) exec -T -u rc rc

help:
	@echo "Local dev (Docker stack):"
	@echo "  make up           start db + rc in the background"
	@echo "  make down         stop and remove containers (volumes preserved)"
	@echo "  make restart      restart rc only (faster than down/up)"
	@echo "  make logs         tail rc logs"
	@echo "  make ps           container status"
	@echo ""
	@echo "Shells:"
	@echo "  make shell        bash inside the rc container"
	@echo "  make iex          attach an iex session to the running phx.server"
	@echo "  make psql         psql into the dev database"
	@echo ""
	@echo "Database:"
	@echo "  make migrate      run pending Ecto migrations"
	@echo "  make seed         (re)run priv/repo/seeds.exs"
	@echo "  make reset-db     drop, create, migrate, seed (DESTROYS dev data)"
	@echo ""
	@echo "Quality:"
	@echo "  make test         MIX_ENV=test mix test (inside the container)"
	@echo "  make test-watch   mix test, re-run on file change"
	@echo "  make format       mix format"
	@echo "  make credo        mix credo --strict (advisory)"
	@echo ""
	@echo "Frontend (only needed when running outside Docker):"
	@echo "  make ni           npm install in assets/ and front/"
	@echo "  make nr           npm rebuild node-sass"
	@echo ""
	@echo "Release build / deploy:"
	@echo "  make build        build prod release tarballs"
	@echo "  make build-back   back-end only"
	@echo "  make upload       scp tarballs to prod nodes"
	@echo ""
	@echo "Distributed dev (not in Docker, needs local Elixir):"
	@echo "  make a | b | c    run node 1/2/3 with iex"

# --- Docker lifecycle ---------------------------------------------------------

up:
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

restart:
	$(COMPOSE) restart rc

logs:
	$(COMPOSE) logs -f --tail=100 rc

ps:
	$(COMPOSE) ps

# --- Shells -------------------------------------------------------------------

shell:
	$(EXEC) bash

iex:
	$(EXEC) iex -S mix

psql:
	$(COMPOSE) exec db psql -U postgres -d gateway_dev

# --- Database -----------------------------------------------------------------

migrate:
	$(EXEC) mix ecto.migrate

seed:
	$(EXEC) mix run priv/repo/seeds.exs

reset-db:
	$(EXEC) mix ecto.reset
	$(COMPOSE) exec rc rm -f /var/lib/rc-state/seeded

# --- Quality ------------------------------------------------------------------

test:
	$(EXEC) sh -c 'MIX_ENV=test mix do deps.get --only test, ecto.create --quiet, ecto.migrate --quiet, test'

test-watch:
	$(EXEC) sh -c 'MIX_ENV=test mix test.watch'

format:
	$(EXEC) mix format

credo:
	$(EXEC) mix credo --strict || true

# --- Frontend (host-side, only when not using Docker) -------------------------

ni:
	cd assets && npm install
	cd front/ && npm install

nr:
	cd assets && npm rebuild node-sass
	cd front/ && npm rebuild node-sass

# --- Release build / deploy ---------------------------------------------------

build:
	@if [ -z "$$VUE_APP_BASE_URL" ]; then \
	  echo "error: VUE_APP_BASE_URL must be set for a prod build"; \
	  echo "  example: VUE_APP_BASE_URL=https://your-domain.example make build"; \
	  exit 1; \
	fi
	echo $(VERSION) > priv/VERSION
	docker build -t build_image \
	  --build-arg APP_REVISION=$(VERSION) \
	  --build-arg BACK_ONLY=false \
	  --build-arg VUE_APP_BASE_URL=$$VUE_APP_BASE_URL \
	  --build-arg VUE_APP_APPSIGNAL_FRONT=$$VUE_APP_APPSIGNAL_FRONT \
	  .
	docker create --name extract build_image
	docker cp extract:/home/rc/build/vue.tar.gz ./build/
	docker cp extract:/home/rc/build/rc.tar.gz ./build/
	docker rm extract

build-back:
	@if [ -z "$$VUE_APP_BASE_URL" ]; then \
	  echo "error: VUE_APP_BASE_URL must be set even for back-only builds"; \
	  echo "  (build args are part of the docker layer cache key — drifting"; \
	  echo "  values can produce a backend whose URL helpers point at a"; \
	  echo "  different host than the deployed Vue bundle)"; \
	  echo "  example: VUE_APP_BASE_URL=https://your-domain.example make build-back"; \
	  exit 1; \
	fi
	echo $(VERSION) > priv/VERSION
	docker build -t build_image \
	  --build-arg APP_REVISION=$(VERSION) \
	  --build-arg BACK_ONLY=true \
	  --build-arg VUE_APP_BASE_URL=$$VUE_APP_BASE_URL \
	  --build-arg VUE_APP_APPSIGNAL_FRONT=$$VUE_APP_APPSIGNAL_FRONT \
	  .
	docker create --name extract build_image
	docker cp extract:/home/rc/build/rc.tar.gz ./build/
	docker rm extract

upload: upload-front upload-back

upload-front:
	./upload-front.sh

upload-back:
	./upload-back.sh

# Full deploy: assumes `make build` has already produced the tarballs. SCPs
# them, stops the service, extracts, runs migrations, restarts. Hosts come
# from nodes.sh.
deploy:
	./deploy/bin/deploy.sh

# --- Distributed-node dev (legacy, needs local Elixir) ------------------------

a:
	mix compile
	PORT=4000 ERL_AFLAGS="-name node_1@127.0.0.1 -setcookie on-est-bien-bien-bien-bien-bien" iex -S mix phx.server
b:
	PORT=4001 ERL_AFLAGS="-name node_2@127.0.0.1 -setcookie on-est-bien-bien-bien-bien-bien" iex -S mix phx.server
c:
	PORT=4002 ERL_AFLAGS="-name node_3@127.0.0.1 -setcookie on-est-bien-bien-bien-bien-bien" iex -S mix phx.server
