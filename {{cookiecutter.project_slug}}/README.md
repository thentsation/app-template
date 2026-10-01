[🇧🇷 Português](README.pt-br.md) | 🇺🇸 English

# {{ cookiecutter.project_name }}

{{ cookiecutter.description }}

## Overview

{% if cookiecutter.platform_mode == 'tenant' -%}
- Public URL (after the deploy is approved): `https://{{ cookiecutter.project_slug }}-{{ cookiecutter.tenant }}.{{ cookiecutter.domain }}`
- Jenkins: `{{ cookiecutter.jenkins_url }}/job/tenants/job/{{ cookiecutter.tenant }}/`
{%- else -%}
- Public URL: `https://{{ cookiecutter.subdomain }}.{{ cookiecutter.domain }}`
{%- endif %}
- Healthcheck: `GET {{ cookiecutter.health_path }}` → `{"status": "ok", "version": "<APP_VERSION>"}`
- Image: `{{ cookiecutter.registry }}/{{ cookiecutter.registry_namespace }}/{{ cookiecutter.project_slug }}`
- Repository: `https://github.com/{{ cookiecutter.github_org }}/{{ cookiecutter.project_slug }}`

## Stack

- Python {{ cookiecutter.python_version }}, FastAPI, Uvicorn, pydantic-settings
- pytest + pytest-cov (minimum coverage 90%), ruff, mypy
- Docker (multi-stage: `deps`, `test`, `runtime`) and Docker Compose
- Jenkins (CI/CD) and Traefik (reverse proxy with TLS)

## Running locally

```bash
make install          # .venv with the locked dependencies + dev tools
cp .env.example .env  # optional
make dev              # http://localhost:{{ cookiecutter.app_port }} with reload
```

With Docker:

```bash
make docker-build     # runtime image tagged {{ cookiecutter.project_slug }}
make docker-run       # http://localhost:{{ cookiecutter.app_port }}
```

## Tests

```bash
make lint typecheck coverage   # ruff, mypy and pytest (fails below 90%)
make docker-test               # the same checks inside the `test` stage
```

The `test` stage of `docker/Dockerfile` runs `ruff check`, `ruff format --check`, `mypy` and `pytest --cov-fail-under=90`; if any of them fails, the build fails.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `APP_NAME` | `{{ cookiecutter.project_name }}` | Name shown in `/` and in the OpenAPI docs |
| `APP_VERSION` | `0.0.0-dev` | Set at build time (`--build-arg APP_VERSION=<short sha>`) |
| `DOCS_ENABLED` | `true` | Enables `/docs` and `/openapi.json` |

- Do not set `APP_VERSION` in `.env` (or in `/opt/apps/{{ cookiecutter.project_slug }}/.env`): it overrides the version baked into the image and the Jenkins validation fails and rolls back.

Compose-only variables (all optional, `docker compose config -q` works without them):

| Variable | Default | Description |
|---|---|---|
| `APP_IMAGE` | `{{ cookiecutter.registry }}/{{ cookiecutter.registry_namespace }}/{{ cookiecutter.project_slug }}:latest` | Image to run |
| `PROXY_NETWORK` | `{{ cookiecutter.proxy_network }}` | External network shared with Traefik |
| `APP_ENV_FILE` | `.env` | Runtime env file (on the server: `/opt/apps/{{ cookiecutter.project_slug }}/.env`) |

## Deploy (Jenkins + Traefik)

The `Jenkinsfile` only calls the platform's standard pipeline (`appPipeline`, Shared Library `platform`). Every branch and PR runs: contract validation, `docker build --check`, `docker build --target test` (ruff, mypy, pytest with at least 90% coverage), `pip-audit` on `config/requirements.lock` and Trivy (CRITICAL/HIGH) on the runtime image.

{% if cookiecutter.platform_mode == 'tenant' -%}
This project belongs to a **tenant** (`{{ cookiecutter.tenant }}`): builds run on an isolated tenant agent with no access to the server. On `{{ cookiecutter.deploy_branch }}`, after CI, the pipeline builds `--target runtime`, runs a smoke test and pushes the image to the tenant registry, tagged with the commit.

To get a public link:

```bash
make jenkins-login     # once: username and password from the admin -> local API token
git push               # {{ cookiecutter.deploy_branch }} publishes the image (scan every 5 min, or: make jenkins-build)
make jenkins-status    # result of the last build of the current branch
make deploy-request    # asks to deploy the latest image (or TAG=<sha>); the admin approves it in Jenkins
make logs              # logs of the published app
make undeploy          # takes the app down
```

Once approved, the app is served at `https://{{ cookiecutter.project_slug }}-{{ cookiecutter.tenant }}.{{ cookiecutter.domain }}` with a Let's Encrypt certificate. Rules: the image must have a `HEALTHCHECK`, run as a non-root user (`USER` in the Dockerfile) and pass Trivy; the container runs with no capabilities and with CPU and memory limits; runtime variables (secrets) are agreed with the admin.

This repo's `docker-compose.yml` is for local runs only (`make compose-up`, port {{ cookiecutter.app_port }} on 127.0.0.1).
{%- else -%}
On `{{ cookiecutter.deploy_branch }}` the pipeline also:

1. builds `--target runtime` with `APP_VERSION=<short sha>` (tags `<sha>` and `latest`);
2. runs a smoke test of the image and waits for `health=healthy`;
3. pushes to `{{ cookiecutter.registry }}`;
4. runs `docker compose up -d --wait` (the previous image is kept for rollback);
5. calls `https://{{ cookiecutter.subdomain }}.{{ cookiecutter.domain }}{{ cookiecutter.health_path }}` through Traefik and rolls back if it does not answer HTTP 200{% if cookiecutter.health_expects_version == 'yes' %} with the new version{% endif %};
6. cuts the release with semantic-release (version, CHANGELOG and tag).

`{{ cookiecutter.deploy_branch }}` is also rebuilt every Monday to pick up security patches. Dependencies: Renovate (Jenkins job `platform/renovate`, devops-platform preset), auto-merging patch/minor once Jenkins approves the PR.

The container does not publish ports. Traefik reaches it through the `{{ cookiecutter.proxy_network }}` network using the labels in `docker-compose.yml` (router `{{ cookiecutter.project_slug }}`, entrypoint `websecure`, cert resolver `letsencrypt`, port `{{ cookiecutter.app_port }}`).
{%- endif %}

## Healthcheck

- Image: `HEALTHCHECK` with Python/urllib on `http://127.0.0.1:{{ cookiecutter.app_port }}{{ cookiecutter.health_path }}`.
- Compose: `{{ cookiecutter.healthcheck_tool }}` on the same URL (interval 15s, timeout 5s, 3 retries, start period 20s).
- Check it: `docker ps --filter name=^{{ cookiecutter.project_slug }}$` (STATUS `(healthy)`)

## Project structure

```
{{ cookiecutter.project_slug }}/
├── config/
│   ├── requirements.txt       # runtime dependencies (exact pins)
│   ├── requirements-dev.txt   # ruff, mypy, pytest...
│   └── requirements.lock      # uv pip compile config/requirements.txt --output-file=config/requirements.lock --universal
├── docker/Dockerfile          # stages deps, test and runtime
├── src/
│   ├── config.py              # settings (pydantic-settings) and HEALTH_PATH
│   ├── main.py                # FastAPI app
│   ├── models.py              # response models
│   └── routes/meta.py         # / and {{ cookiecutter.health_path }}
├── tests/
├── docker-compose.yml         # service `app` behind Traefik
├── Jenkinsfile                # CI/CD pipeline
├── Makefile
├── pyproject.toml             # ruff, mypy, coverage, semantic-release
└── pytest.ini
```
