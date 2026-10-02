# app-template

Template [cookiecutter](https://cookiecutter.readthedocs.io/) de uma API FastAPI pronta para a plataforma de CI/CD (Jenkins + Traefik) do [devops-platform](https://github.com/thentsation/devops-platform): Dockerfile multi-stage com lint, tipagem e testes, healthcheck, Jenkinsfile que chama o pipeline padrão da plataforma e Renovate para as dependências.

## Gerar um projeto

```bash
# com o cookiecutter instalado (ou: uvx cookiecutter ...)
cookiecutter https://github.com/thentsation/app-template.git
```

O template tem dois modos (`platform_mode`):

| Modo | Para quem | O que a `main` faz |
|---|---|---|
| `platform` | repos da organização | build, smoke test, push para o OCIR, deploy atrás do Traefik com rollback, release (semantic-release) |
| `tenant` | projetos de terceiros hospedados na plataforma | build e testes num agente isolado do tenant e publicação da imagem no registry do tenant; o link público sai por um pedido de deploy aprovado pelo admin |

### Modo tenant (projeto de terceiro)

Você recebe do admin: o nome do tenant, um usuário e uma senha do Jenkins e a **URL de webhook** do seu tenant. Então:

```bash
cookiecutter https://github.com/thentsation/app-template.git platform_mode=tenant tenant=<seu-tenant> project_name=<nome-do-repo>
cd <nome-do-repo>
git init -b main && git add -A && git commit -m "feat: projeto inicial"
git remote add origin <url https do seu repo> && git push -u origin main
```

No seu repo (GitHub, GitLab, Gitea...), crie um **webhook de push** com a URL recebida do admin e content type `application/json`. A partir daí cada push cadastra o repo no Jenkins (na primeira vez) e roda o pipeline na hora; não precisa pedir nada ao admin. Repo privado: combine com o admin um token de leitura.

```bash
make jenkins-login     # uma vez: gera um API token do Jenkins (~/.config/devops-platform/)
make jenkins-status    # resultado do último build da branch atual
make deploy-request    # pede o deploy público da última imagem da main; o admin aprova
make logs              # logs do app publicado
make undeploy          # tira o app do ar
```

O app aprovado fica em `https://<projeto>-<tenant>.137-131-175-7.sslip.io`. Regras do ambiente:

- a imagem precisa de `HEALTHCHECK`, de um `USER` sem privilégio e de passar no Trivy (CRITICAL/HIGH com correção);
- o container roda sem capabilities, sem portas publicadas e com limites de CPU, memória e processos;
- os builds rodam num Docker próprio do tenant, sem acesso ao servidor nem à rede interna;
- segredos de runtime do app são combinados com o admin (ficam num `.env` no servidor, fora do repo).

### Repo que já existe (modo tenant)

Para um projeto que já tem repo, não precisa do cookiecutter. Na raiz do repo:

```bash
curl -fsSL https://raw.githubusercontent.com/thentsation/app-template/main/adopt.sh \
  | bash -s -- --tenant <seu-tenant> [--app nome] [--port 8000] [--health /health] [--branch main]
```

Ambiente de teste: com `--run job` (ingestão, batch, script) ou `--run service` (API, web), cada push na branch roda a imagem **uma vez** no Docker isolado do seu tenant e derruba: o job passa se terminar com código 0; o serviço passa se ficar healthy. Os logs ficam no build do Jenkins e nada fica no ar (`--timeout` em minutos, padrão 15). O deploy permanente (`make deploy-request`) continua opcional.

O script cria o `Jenkinsfile` e o `scripts/platform.sh`, acrescenta os alvos `make` ao Makefile, move o `Dockerfile` da raiz para `docker/Dockerfile` e nomeia o último estágio como `runtime`. Ele confere `HEALTHCHECK` e `USER` e avisa o que falta (isso você ajusta à mão). Não faz commit: revise com `git diff`, faça commit e push e configure o webhook.

Exemplo de `docker/Dockerfile` mínimo (qualquer linguagem; o que importa é o estágio `runtime`, o `HEALTHCHECK` e o `USER`):

```dockerfile
FROM python:3.12-slim AS runtime
WORKDIR /app
COPY . .
RUN pip install --no-cache-dir -r requirements.txt && useradd -m app
USER app
EXPOSE 8000
HEALTHCHECK CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=4)"
CMD ["python", "main.py"]
```

O container não tem disco persistente (banco de dados precisa ser externo) e roda sem privilégios.

### Modo platform (repos da organização)

```bash
cookiecutter https://github.com/thentsation/app-template.git project_name="Minha API"
```

O repo precisa estar na organização (a organization folder do Jenkins descobre os repos com `Jenkinsfile`) e ter o webhook da organização. O Renovate usa o preset `local>thentsation/devops-platform//renovate/default`.

## Opções

| Chave | Padrão | Observação |
|---|---|---|
| `platform_mode` | `platform` | `platform` ou `tenant` |
| `tenant` | | obrigatório no modo `tenant` |
| `project_name` / `project_slug` | `Minha Aplicacao` / derivado | no modo tenant o slug tem até 31 caracteres |
| `domain` / `subdomain` | `137-131-175-7.sslip.io` / slug | host público no modo platform |
| `app_port` | `8000` | |
| `health_path` | `/health` | |
| `health_expects_version` | `yes` | o health devolve a versão (SHA do build) |
| `healthcheck_tool` | `python` | `python`, `curl` ou `wget` (healthcheck do compose) |
| `deploy_branch` | `main` | |
| `jenkins_url` | `https://jenkins.137-131-175-7.sslip.io` | usado pelo CLI do modo tenant |

O contrato completo (Dockerfile, compose, health) está em `docs/ARCHITECTURE.md` do devops-platform.

## Testes do template

```bash
tests/test_template.sh   # gera projetos nos dois modos, roda build/test/smoke e valida via um Traefik descartável
```
