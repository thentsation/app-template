# Hospedando seu projeto na plataforma

Guia para quem vai usar o Jenkins da plataforma como tenant (projeto de terceiro).

## O que é

Você ganha um Jenkins para o seu projeto: a cada push, ele faz o build, roda os testes e o scan de segurança e testa a sua app num Docker isolado só seu. Se quiser, a app também ganha um link público com HTTPS. O seu repo pode ficar onde já está (GitHub, GitLab, Gitea...).

| Tipo de projeto | Suporte | Como roda |
| --- | --- | --- |
| API (REST, GraphQL), app web (Flask, Streamlit, Next.js), site estático, websocket | Sim | Execução de teste a cada push e, se você pedir, link público |
| Ingestão, batch, ETL, script | Sim, como teste | Roda uma vez a cada push e termina; passa se sair com código 0 |
| Biblioteca ou ferramenta de linha de comando | Em parte | Testes e scan rodam; não há o que publicar |
| Worker sempre no ar sem HTTP, app com vários containers, banco ou disco persistente, GPU, serverless | Não | Fale com o admin antes |

Tudo roda em containers com limite de CPU e memória, sem privilégios e sem acesso à rede interna do servidor. A internet é liberada.

```
git push ──► build, testes e scan ──► execução de teste (roda 1 vez e é derrubada)
                (Docker isolado)                │
                                                │ opcional, só API/web
                                                ▼
     link público ◄── admin aprova ◄── make deploy-request
```

## O que pedir ao admin

Antes de começar, mande ao admin:

- **O nome que você quer usar** (o seu "tenant"): de 2 a 10 letras minúsculas e números, começando por letra. Exemplo: `joao`.
- **O tipo do projeto**: API/web ou ingestão/batch (ver a tabela acima).
- **Só se o repo for privado**: um token de leitura só desse repo (no GitHub, um fine-grained token com Contents: read-only). Repo público não precisa.
- **Só se a app precisar de segredos** (chave de API, senha de banco externo): combine com o admin como passar. Nunca coloque segredos no repo.

O admin te devolve:

| O que | Para que serve |
| --- | --- |
| URL do Jenkins: https://jenkins.137-131-175-7.sslip.io | Acompanhar os builds |
| Usuário e senha do Jenkins | `make jenkins-login`. Troque a senha no seu perfil do Jenkins (canto superior direito) |
| URL de webhook pessoal (`.../generic-webhook-trigger/invoke?token=...`) | Colar no seu repo; trate como senha |

## Passo a passo

Você precisa de `git`, `curl`, `make` e Docker na sua máquina (Docker só para testar localmente).

### Se você já tem o repo

Na raiz do repo, um comando prepara tudo (troque `joao` pelo seu tenant):

```bash
curl -fsSL https://raw.githubusercontent.com/thentsation/app-template/main/adopt.sh \
  | bash -s -- --tenant joao --run service
```

- `--run service` para API/web; `--run job` para ingestão/batch/script.
- Se a app não usa a porta 8000 ou o endpoint `/health`, acrescente `--port 3000 --health /status`.
- O script cria o `Jenkinsfile` e o `scripts/platform.sh`, acrescenta os comandos `make` ao Makefile e move o `Dockerfile` para `docker/Dockerfile`. Ele **não** faz commit e avisa (com `!`) o que você precisa ajustar à mão.

Depois:

1. Corrija o que o script marcou com `!` (ver [Requisitos do Dockerfile](#requisitos-do-dockerfile)).
2. Revise com `git diff`, faça commit e push.
3. Configure o webhook (seção abaixo).

### Se o projeto é novo (API em Python)

```bash
uvx cookiecutter https://github.com/thentsation/app-template.git platform_mode=tenant tenant=joao project_name=minha-api
cd minha-api
git init -b main && git add -A && git commit -m "feat: projeto inicial"
git remote add origin <url https do seu repo>
git push -u origin main
```

O projeto já vem com API FastAPI, testes, Dockerfile e Jenkinsfile prontos. O `project_name` deve ser igual ao nome do repo. Depois configure o webhook.

## Requisitos do Dockerfile

O build usa `docker/Dockerfile`, com a raiz do repo como contexto. Funciona com qualquer linguagem.

| Requisito | Por quê |
| --- | --- |
| Último estágio chamado `runtime` (`FROM ... AS runtime`) | É a imagem que roda |
| `USER` sem privilégio no final | Imagem que roda como root é recusada |
| `HEALTHCHECK` (só para API/web) | É assim que a plataforma sabe que a app subiu |
| Passar no Trivy | Vulnerabilidade CRITICAL ou HIGH com correção disponível falha o build: atualize a imagem base |
| Sem avisos no `docker build --check` | Avisos de boas práticas falham o build |
| Opcional: estágio `test` | Se existir, roda lint e testes; o build falha se um teste falhar |

Exemplo mínimo de uma API na porta 8000:

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

Para ingestão/batch, o mesmo sem `HEALTHCHECK` e `EXPOSE`: o `CMD` roda o script e termina. Nada gravado em disco dentro do container sobrevive; grave em um destino externo (banco ou bucket seu).

## Configurar o webhook

Com o webhook, cada push dispara o build na hora. No primeiro push o Jenkins cadastra o seu repo sozinho; você não precisa pedir nada ao admin.

| Onde | Caminho | O que preencher |
| --- | --- | --- |
| GitHub | Settings → Webhooks → Add webhook | Payload URL = a URL do admin; Content type = `application/json`; evento "Just the push event" |
| GitLab | Settings → Webhooks → Add new webhook | URL = a URL do admin; marque "Push events" |
| Gitea | Settings → Webhooks → Add Webhook → Gitea | Target URL = a URL do admin; POST Content Type = `application/json`; evento Push |

- O repo precisa ser acessível por HTTPS (a URL de clone `https://...`).
- Cada tenant pode ter até 10 repos.
- A URL do webhook é como uma senha. Se vazar, peça ao admin uma nova; a antiga para de funcionar.
- Sem webhook também funciona, só que mais devagar: depois que o repo está cadastrado, o Jenkins confere a cada 5 minutos (ou rode `make jenkins-build`).

## Teste, deploy e comandos do dia a dia

Todo push roda o build, os testes e o scan. Na branch principal (`main`), a sua app também roda **uma vez** num Docker isolado e é derrubada:

- **API/web** (`run: [mode: 'service']`): passa se a app ficar saudável (`HEALTHCHECK`).
- **Ingestão/batch** (`run: [mode: 'job']`): passa se o processo terminar com código 0. O limite é de 15 minutos (`timeout` no `Jenkinsfile` muda isso).

Os logs da execução ficam no build do Jenkins. Nada fica no ar e o admin não precisa aprovar.

**Link público (opcional, só API/web):** rode `make deploy-request`. O admin aprova no Jenkins e a app fica no ar em `https://<projeto>-<tenant>.137-131-175-7.sslip.io`. Cada nova versão precisa de um novo pedido.

| Comando | O que faz |
| --- | --- |
| `make jenkins-login` | Uma vez: pede usuário e senha e guarda um token em `~/.config/devops-platform/` |
| `make jenkins-status` | Resultado do último build da branch atual, com o link |
| `make jenkins-build` | Pede ao Jenkins para olhar o repo agora |
| `make deploy-request` | Pede o link público da última imagem da `main` (ou `make deploy-request TAG=<sha>`) |
| `make logs` | Logs da app publicada (`LINES=500` para mais linhas) |
| `make undeploy` | Tira a app publicada do ar |

No Jenkins você só enxerga a sua pasta: `tenants/<seu tenant>/`.

## Regras, limites e problemas comuns

**Limites padrão** (o admin pode aumentar): app publicada com 0,5 CPU e 512 MB de RAM; execução de teste com 1 CPU, 1 GB e 15 minutos; build com 1 CPU e 2 GB.

**O que não é permitido:** rodar como root, pedir privilégios, publicar portas direto, acessar a rede interna do servidor ou enviar e-mail pela porta 25. É um ambiente de testes e estudos: não use para nada crítico.

| Sintoma | Causa provável e solução |
| --- | --- |
| Falha em "Validação estática" | Aviso no Dockerfile: rode `docker build --check -f docker/Dockerfile .` localmente e corrija |
| Falha no Trivy | Vulnerabilidade na imagem base ou numa dependência: atualize a versão e faça push de novo |
| "a imagem roda como root" | Falta `USER` sem privilégio no fim do Dockerfile |
| Execução de teste não fica healthy | O `HEALTHCHECK` chama a porta ou o caminho errado; teste local com `docker run` |
| Job falha com código diferente de 0 | O erro está nos logs do build, na etapa "Execução de teste" |
| Push não dispara build | Confira o webhook (content type `application/json`, evento push) e o status da entrega no seu provedor |
| `make jenkins-login` recusado | Usuário ou senha errados, ou a senha foi trocada: peça uma nova ao admin |

Dúvidas ou algo fora desta tabela: mande ao admin o link do build no Jenkins.
