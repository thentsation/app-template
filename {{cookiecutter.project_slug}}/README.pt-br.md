🇧🇷 Português | [🇺🇸 English](README.md)

# {{ cookiecutter.project_name }}

{{ cookiecutter.description }}

## Visão geral

{% if cookiecutter.platform_mode == 'tenant' -%}
- URL pública (depois do deploy aprovado): `https://{{ cookiecutter.project_slug }}-{{ cookiecutter.tenant }}.{{ cookiecutter.domain }}`
- Jenkins: `{{ cookiecutter.jenkins_url }}/job/tenants/job/{{ cookiecutter.tenant }}/`
{%- else -%}
- URL pública: `https://{{ cookiecutter.subdomain }}.{{ cookiecutter.domain }}`
{%- endif %}
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

- Não defina `APP_VERSION` no `.env` (nem em `/opt/apps/{{ cookiecutter.project_slug }}/.env`): ela sobrescreve a versão gravada na imagem e a validação do Jenkins falha e faz rollback.

Variáveis só do compose (todas opcionais, `docker compose config -q` funciona sem elas):

| Variável | Padrão | Descrição |
|---|---|---|
| `APP_IMAGE` | `{{ cookiecutter.registry }}/{{ cookiecutter.registry_namespace }}/{{ cookiecutter.project_slug }}:latest` | Imagem a executar |
| `PROXY_NETWORK` | `{{ cookiecutter.proxy_network }}` | Rede externa compartilhada com o Traefik |
| `APP_ENV_FILE` | `.env` | Arquivo de variáveis de runtime (no servidor: `/opt/apps/{{ cookiecutter.project_slug }}/.env`) |

## Deploy (Jenkins + Traefik)

O `Jenkinsfile` só chama o pipeline padrão da plataforma (`appPipeline`, Shared Library `platform`). Toda branch e PR roda: validação do contrato, `docker build --check`, `docker build --target test` (ruff, mypy, pytest com cobertura mínima de 90%), `pip-audit` do `config/requirements.lock` e Trivy (CRITICAL/HIGH) na imagem de runtime.

{% if cookiecutter.platform_mode == 'tenant' -%}
Este projeto é de um **tenant** (`{{ cookiecutter.tenant }}`): os builds rodam num agente isolado do tenant, sem acesso ao servidor. Na `{{ cookiecutter.deploy_branch }}`, depois do CI, o pipeline faz o build `--target runtime`, roda um smoke test e publica a imagem no registry do tenant com a tag do commit.

Para ter o link público:

```bash
make jenkins-login     # uma vez: usuário e senha recebidos do admin -> API token local
git push               # a {{ cookiecutter.deploy_branch }} publica a imagem (scan a cada 5 min ou: make jenkins-build)
make jenkins-status    # resultado do último build da branch atual
make deploy-request    # pede o deploy da última imagem (ou TAG=<sha>); o admin aprova no Jenkins
make logs              # logs do app publicado
make undeploy          # tira o app do ar
```

Depois da aprovação, o app fica em `https://{{ cookiecutter.project_slug }}-{{ cookiecutter.tenant }}.{{ cookiecutter.domain }}`, com HTTPS do Let's Encrypt. Regras do ambiente: a imagem precisa ter `HEALTHCHECK`, rodar com usuário sem privilégio (`USER` no Dockerfile) e passar no Trivy; o container roda sem capabilities e com limites de CPU e memória; variáveis de runtime (segredos) são combinadas com o admin.

O `docker-compose.yml` deste repo é só para rodar local (`make compose-up`, porta {{ cookiecutter.app_port }} em 127.0.0.1).
{%- else -%}
Na `{{ cookiecutter.deploy_branch }}` o pipeline também:

1. faz o build `--target runtime` com `APP_VERSION=<sha curto>` (tags `<sha>` e `latest`);
2. roda um smoke test da imagem e espera `health=healthy`;
3. faz push para o `{{ cookiecutter.registry }}`;
4. roda `docker compose up -d --wait` (a imagem anterior fica guardada para rollback);
5. chama `https://{{ cookiecutter.subdomain }}.{{ cookiecutter.domain }}{{ cookiecutter.health_path }}` pelo Traefik e faz rollback se não vier HTTP 200{% if cookiecutter.health_expects_version == 'yes' %} com a versão nova{% endif %};
6. gera o release com o semantic-release (versão, CHANGELOG e tag).

A `{{ cookiecutter.deploy_branch }}` também é reconstruída toda segunda para pegar patches de segurança. Dependências: Renovate (job `platform/renovate` no Jenkins, preset do devops-platform), com auto-merge de patch/minor depois que o Jenkins aprova o PR.

O container não publica portas. O Traefik chega nele pela rede `{{ cookiecutter.proxy_network }}` usando as labels do `docker-compose.yml` (router `{{ cookiecutter.project_slug }}`, entrypoint `websecure`, cert resolver `letsencrypt`, porta `{{ cookiecutter.app_port }}`).
{%- endif %}

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
