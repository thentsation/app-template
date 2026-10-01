# Contrato (docs/ARCHITECTURE.md): stages `test` e `runtime`, ARG APP_VERSION e HEALTHCHECK.
ARG PYTHON_VERSION={{ cookiecutter.python_version }}

# Dependencias de runtime, instaladas a partir do lockfile.
FROM python:${PYTHON_VERSION}-slim AS deps

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_ROOT_USER_ACTION=ignore

WORKDIR /app

COPY config/requirements.lock ./config/

RUN pip install --prefix=/install -r ./config/requirements.lock

# Lint, tipagem e testes. Qualquer falha derruba o build.
FROM python:${PYTHON_VERSION}-slim AS test

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_ROOT_USER_ACTION=ignore \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

COPY --from=deps /install /usr/local
COPY config/requirements-dev.txt ./config/
RUN pip install -r ./config/requirements-dev.txt

COPY pyproject.toml pytest.ini ./
COPY src ./src
COPY tests ./tests

RUN ruff check . \
    && ruff format --check . \
    && mypy \
    && pytest --cov=src --cov-report=term-missing --cov-fail-under=90

# Imagem final.
FROM python:${PYTHON_VERSION}-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

{% if cookiecutter.healthcheck_tool == 'python' -%}
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*
{%- else -%}
# {{ cookiecutter.healthcheck_tool }} e usado pelo healthcheck do docker-compose.yml.
RUN apt-get update && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends {{ cookiecutter.healthcheck_tool }} \
    && rm -rf /var/lib/apt/lists/*
{%- endif %}

COPY --from=deps /install /usr/local

RUN useradd --create-home --uid 10001 appuser

COPY src ./src

USER appuser

ARG APP_VERSION=0.0.0-dev
ENV APP_VERSION=${APP_VERSION}

EXPOSE {{ cookiecutter.app_port }}

HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
    CMD ["python", "-c", "import sys, urllib.request; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:{{ cookiecutter.app_port }}{{ cookiecutter.health_path }}', timeout=4).status == 200 else 1)"]

CMD ["uvicorn", "main:app", "--app-dir", "src", "--host", "0.0.0.0", "--port", "{{ cookiecutter.app_port }}", "--no-access-log"]
