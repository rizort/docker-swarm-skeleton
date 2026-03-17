# Variables can be set in .env (or via environment). Example: .env.dist
-include .env

# Initialization: creates .env from template and moves the sample in src/ to src/.env.dist
.PHONY: init
init:
	[ -f .env ] || cp .env.dist .env

# Registry and image settings
REGISTRY ?= localhost:5000
REGISTRY_USER ?=
REGISTRY_PASSWORD ?=
STACK_NAME ?= swarm-app

# Semantic version (read from .env: VERSION)
VERSION ?= $(shell [ -f .env ] && grep -E '^VERSION=' .env | head -n1 | cut -d= -f2- || echo "0.1.0")
TAG := $(VERSION)

PHP_IMAGE = $(REGISTRY)/swarm-php:$(TAG)
NGINX_IMAGE = $(REGISTRY)/swarm-nginx:$(TAG)

# Build Docker images
.PHONY: build
build:
	docker build -t $(PHP_IMAGE) -f docker/Dockerfile.php .
	docker build -t $(NGINX_IMAGE) -f docker/Dockerfile.nginx .

# Push images to registry
.PHONY: push
push:
	docker push $(PHP_IMAGE)
	docker push $(NGINX_IMAGE)

# Push images (used by release targets)
.PHONY: release
release: push

# Semantic version bump helpers (update VERSION in .env)
define bump_version
	@current=$$(grep -E '^VERSION=' .env 2>/dev/null | head -n1 | cut -d= -f2- || echo "0.1.0"); \
	major=$$(echo $$current | cut -d. -f1); \
	minor=$$(echo $$current | cut -d. -f2); \
	patch=$$(echo $$current | cut -d. -f3); \
	$(1) \
	new=$$major.$$minor.$$patch; \
	if grep -qE '^VERSION=' .env 2>/dev/null; then \
		sed -i 's/^VERSION=.*/VERSION='"$$new"'/' .env; \
	else \
		echo "VERSION=$$new" >> .env; \
	fi; \
	echo "Bumped version -> $$new";
endef

.PHONY: release-major
release-major:
	$(call bump_version,major=$$((major+1)); minor=0; patch=0)
	$(MAKE) TAG=$$(grep -E '^VERSION=' .env | cut -d= -f2-) build push

.PHONY: release-minor
release-minor:
	$(call bump_version,minor=$$((minor+1)); patch=0)
	$(MAKE) TAG=$$(grep -E '^VERSION=' .env | cut -d= -f2-) build push

.PHONY: release-patch
release-patch:
	$(call bump_version,patch=$$((patch+1)))
	$(MAKE) TAG=$$(grep -E '^VERSION=' .env | cut -d= -f2-) build push

# View service status
.PHONY: status
status:
	docker stack services $(STACK_NAME)

# Start services locally (docker compose)
.PHONY: dev-up
dev-up:
	# Ensure local secret exists (so docker compose can mount it)
	@mkdir -p docker/development/secrets
	@[ -f docker/development/secrets/app_secret ] || cp docker/development/secrets/app_secret.example docker/development/secrets/app_secret
	docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build

.PHONY: dev-down
dev-down:
	docker compose -f docker-compose.yml -f docker-compose.dev.yml down

# Start services in Swarm mode (prod)
.PHONY: prod-up
prod-up:
	REGISTRY=$(REGISTRY) TAG=$(TAG) docker stack deploy -c docker-compose.yml -c docker-compose.prod.yml $(STACK_NAME)

.PHONY: prod-down
prod-down:
	docker stack rm $(STACK_NAME)

# Remote deploy over SSH (assumes the host can access the registry and has docker stack)
SSH_HOST ?=
SSH_KEY ?= ~/.ssh/id_rsa
REMOTE_DIR ?= ~/swarm-app
SSH_KEY_OPT := $(if $(SSH_KEY),-i $(SSH_KEY),)

.PHONY: deploy
deploy:
ifneq ($(SSH_HOST),)
	# Initialize swarm if not active; docker node ls only works on manager
	@ssh $(SSH_KEY_OPT) $(SSH_HOST) "docker info --format '{{.Swarm.LocalNodeState}}' | grep -q active || docker swarm init >/dev/null 2>&1; docker node ls > /dev/null 2>&1 || { echo 'ERROR: this node is not a swarm manager.' >&2; exit 1; }"

	# Create remote dir
	@ssh $(SSH_KEY_OPT) $(SSH_HOST) "mkdir -p $(REMOTE_DIR)"

	# Copy compose files
	@scp $(SSH_KEY_OPT) docker-compose.yml docker-compose.prod.yml $(SSH_HOST):$(REMOTE_DIR)/

	# Deploy stack with registry auth if credentials are set
	@ssh $(SSH_KEY_OPT) $(SSH_HOST) "cd $(REMOTE_DIR) && if [ -n '$(REGISTRY_USER)' ] && [ -n '$(REGISTRY_PASSWORD)' ]; then printf '%s' '$(REGISTRY_PASSWORD)' | docker login $(REGISTRY) -u '$(REGISTRY_USER)' --password-stdin; else echo 'WARN: REGISTRY_USER or REGISTRY_PASSWORD not set, skipping docker login'; fi && if [ -n '$(APP_SECRET)' ]; then (docker secret inspect app_secret >/dev/null 2>&1 && docker secret rm app_secret >/dev/null 2>&1) || true; printf '%s' '$(APP_SECRET)' | docker secret create app_secret -; fi && REGISTRY=$(REGISTRY) TAG=$(TAG) docker stack deploy --with-registry-auth --prune --detach=true -c docker-compose.yml -c docker-compose.prod.yml $(STACK_NAME)"
else
	@echo "ERROR: SSH_HOST is not set. Use SSH_HOST=user@host make deploy"
	exit 1
endif
