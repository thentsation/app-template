.PHONY: install run dev test coverage lint format typecheck docker-build docker-test docker-run compose-config clean
{%- if cookiecutter.platform_mode == 'tenant' %}
.PHONY: compose-up compose-down jenkins-login jenkins-build jenkins-status deploy-request logs undeploy
{%- endif %}

VENV := .venv
PYTHON := $(VENV)/bin/python
PIP := $(VENV)/bin/pip
IMAGE := {{ cookiecutter.project_slug }}
APP_PORT := {{ cookiecutter.app_port }}
APP_VERSION ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo 0.0.0-dev)

install:
	python3 -m venv $(VENV)
	$(PIP) install --upgrade pip
	$(PIP) install -r config/requirements.lock
	$(PIP) install -r config/requirements-dev.txt

run:
	$(PYTHON) src/main.py

dev:
	$(VENV)/bin/uvicorn main:app --app-dir src --reload --host 0.0.0.0 --port $(APP_PORT)

test:
	$(PYTHON) -m pytest

coverage:
	$(PYTHON) -m pytest --cov=src --cov-report=term-missing --cov-fail-under=90

lint:
	$(VENV)/bin/ruff check .
	$(VENV)/bin/ruff format --check .

format:
	$(VENV)/bin/ruff format .

typecheck:
	$(VENV)/bin/mypy

docker-test:
	docker build -f docker/Dockerfile --target test .

docker-build:
	docker build -f docker/Dockerfile --target runtime --build-arg APP_VERSION=$(APP_VERSION) -t $(IMAGE) .

docker-run:
	docker run --rm -p $(APP_PORT):$(APP_PORT) $(IMAGE)

compose-config:
	docker compose config -q

clean:
	find . -type d -name __pycache__ -not -path './$(VENV)/*' -exec rm -rf {} +
	find . -type d -name .pytest_cache -not -path './$(VENV)/*' -exec rm -rf {} +
	find . -type f -name '*.pyc' -not -path './$(VENV)/*' -delete
	rm -f .coverage
{%- if cookiecutter.platform_mode == 'tenant' %}

# --- Rodar local com o compose de desenvolvimento ---------------------------------
compose-up:
	docker compose up -d --build

compose-down:
	docker compose down

# --- Jenkins da plataforma (tenant {{ cookiecutter.tenant }}; ver scripts/platform.sh) -----------
jenkins-login:
	@scripts/platform.sh login

jenkins-build:
	@scripts/platform.sh build

jenkins-status:
	@scripts/platform.sh status

deploy-request:
	@TAG=$(TAG) scripts/platform.sh deploy-request

logs:
	@LINES=$(LINES) scripts/platform.sh logs

undeploy:
	@scripts/platform.sh undeploy
{%- endif %}
