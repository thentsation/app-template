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
