🇧🇷 Português | [🇺🇸 English](README.md)

# {{ cookiecutter.project_name }}

{{ cookiecutter.description }}

## Visão geral

- URL pública: `https://{{ cookiecutter.subdomain }}.{{ cookiecutter.domain }}`
- Healthcheck: `GET {{ cookiecutter.health_path }}` → `{"status": "ok", "version": "<APP_VERSION>"}`
- Imagem: `{{ cookiecutter.registry }}/{{ cookiecutter.registry_namespace }}/{{ cookiecutter.project_slug }}`
- Repositório: `https://github.com/{{ cookiecutter.github_org }}/{{ cookiecutter.project_slug }}`

## Stack

- Python {{ cookiecutter.python_version }}, FastAPI, Uvicorn, pydantic-settings
- pytest + pytest-cov (cobertura mínima de 90%), ruff, mypy
- Docker (multi-stage: `deps`, `test`, `runtime`) e Docker Compose
- Jenkins (CI/CD) e Traefik (proxy reverso com TLS)

## Como rodar local

```bash
make install          # .venv com as dependências travadas + ferramentas de dev
cp .env.example .env  # opcional
make dev              # http://localhost:{{ cookiecutter.app_port }} com reload
```

Com Docker:

```bash
make docker-build     # imagem runtime com a tag {{ cookiecutter.project_slug }}
make docker-run       # http://localhost:{{ cookiecutter.app_port }}
```

## Testes

```bash
make lint typecheck coverage   # ruff, mypy e pytest (falha abaixo de 90%)
make docker-test               # as mesmas checagens dentro do stage `test`
```

O stage `test` do `docker/Dockerfile` roda `ruff check`, `ruff format --check`, `mypy` e `pytest --cov-fail-under=90`; se algum falhar, o build falha.

## Variáveis de ambiente

| Variável | Padrão | Descrição |
|---|---|---|
| `APP_NAME` | `{{ cookiecutter.project_name }}` | Nome exibido em `/` e na documentação OpenAPI |
| `APP_VERSION` | `0.0.0-dev` | Definida no build (`--build-arg APP_VERSION=<sha curto>`) |
| `DOCS_ENABLED` | `true` | Habilita `/docs` e `/openapi.json` |

Variáveis só do compose (todas opcionais, `docker compose config -q` funciona sem elas):

| Variável | Padrão | Descrição |
|---|---|---|
| `APP_IMAGE` | `{{ cookiecutter.registry }}/{{ cookiecutter.registry_namespace }}/{{ cookiecutter.project_slug }}:latest` | Imagem a executar |
| `PROXY_NETWORK` | `{{ cookiecutter.proxy_network }}` | Rede externa compartilhada com o Traefik |
| `APP_ENV_FILE` | `.env` | Arquivo de variáveis de runtime (no servidor: `/opt/apps/{{ cookiecutter.project_slug }}/.env`) |

## Deploy (Jenkins + Traefik)

Toda branch e pull request roda o CI no Jenkins: `docker compose config -q`, `docker build --check` e `docker build --target test`.
Na `{{ cookiecutter.deploy_branch }}` o pipeline também:

1. faz o build `--target runtime` com `APP_VERSION=<sha curto>` (tags `<sha>` e `latest`);
2. roda um smoke test da imagem e espera `health=healthy`;
3. faz push para o `{{ cookiecutter.registry }}`;
4. roda `docker compose up -d --wait` (a imagem anterior fica guardada para rollback);
5. chama `https://{{ cookiecutter.subdomain }}.{{ cookiecutter.domain }}{{ cookiecutter.health_path }}` pelo Traefik e faz rollback se não vier HTTP 200{% if cookiecutter.health_expects_version == 'yes' %} com a versão nova{% endif %}.

O container não publica portas. O Traefik chega nele pela rede `{{ cookiecutter.proxy_network }}` usando as labels do `docker-compose.yml` (router `{{ cookiecutter.project_slug }}`, entrypoint `websecure`, cert resolver `letsencrypt`, porta `{{ cookiecutter.app_port }}`).

## Healthcheck

- Imagem: `HEALTHCHECK` com Python/urllib em `http://127.0.0.1:{{ cookiecutter.app_port }}{{ cookiecutter.health_path }}`.
- Compose: `{{ cookiecutter.healthcheck_tool }}` na mesma URL (intervalo 15s, timeout 5s, 3 tentativas, start period 20s).
- Conferir: `docker ps --filter name=^{{ cookiecutter.project_slug }}$` (STATUS `(healthy)`)

## Estrutura de pastas

```
{{ cookiecutter.project_slug }}/
├── config/
│   ├── requirements.txt       # dependências de runtime (pin exato)
│   ├── requirements-dev.txt   # ruff, mypy, pytest...
│   └── requirements.lock      # uv pip compile config/requirements.txt -o config/requirements.lock --universal
├── docker/Dockerfile          # stages deps, test e runtime
├── src/
│   ├── config.py              # configurações (pydantic-settings) e HEALTH_PATH
│   ├── main.py                # app FastAPI
│   ├── models.py              # modelos de resposta
│   └── routes/meta.py         # / e {{ cookiecutter.health_path }}
├── tests/
├── docker-compose.yml         # serviço `app` atrás do Traefik
├── Jenkinsfile                # pipeline de CI/CD
├── Makefile
├── pyproject.toml             # ruff, mypy, coverage, semantic-release
└── pytest.ini
```
