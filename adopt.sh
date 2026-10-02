#!/usr/bin/env bash
# Prepara um repo EXISTENTE para rodar na plataforma como tenant (sem recriar o projeto).
#
# Uso, na raiz do repo:
#   curl -fsSL https://raw.githubusercontent.com/thentsation/app-template/main/adopt.sh \
#     | bash -s -- --tenant <seu-tenant> [opções]
#
# Opções:
#   --tenant NOME     nome do tenant recebido do admin (obrigatório)
#   --app NOME        nome do app (padrão: nome da pasta do repo, em minúsculas)
#   --port N          porta HTTP da app no container (padrão: 8000)
#   --health CAMINHO  endpoint de saúde que responde 200 (padrão: /health)
#   --branch NOME     branch que publica a imagem (padrão: main)
#   --jenkins URL     URL do Jenkins (padrão: https://jenkins.137-131-175-7.sslip.io)
#   --force           sobrescreve Jenkinsfile e scripts/platform.sh existentes
#
# O que faz:
#   - Jenkinsfile com o pipeline da plataforma (appPipeline, modo tenant)
#   - scripts/platform.sh + alvos no Makefile (jenkins-login, jenkins-status,
#     deploy-request, logs, undeploy)
#   - move ./Dockerfile para docker/Dockerfile e nomeia o último estágio "runtime"
#   - confere HEALTHCHECK e USER e diz o que falta (não altera isso sozinho)
# Não faz commit nem push: revise com git diff.
set -Eeuo pipefail

TEMPLATE_RAW="${TEMPLATE_RAW:-https://raw.githubusercontent.com/thentsation/app-template/main}"
TENANT=""
APP=""
PORT=8000
HEALTH=/health
BRANCH=main
JENKINS=https://jenkins.137-131-175-7.sslip.io
FORCE=0

die() { printf 'erro: %s\n' "$*" >&2; exit 1; }
info() { printf '  - %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }
WARNINGS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tenant) TENANT="${2:?}"; shift ;;
        --app) APP="${2:?}"; shift ;;
        --port) PORT="${2:?}"; shift ;;
        --health) HEALTH="${2:?}"; shift ;;
        --branch) BRANCH="${2:?}"; shift ;;
        --jenkins) JENKINS="${2:?}"; shift ;;
        --force) FORCE=1 ;;
        -h | --help) sed -n '2,24p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "opção desconhecida: $1" ;;
    esac
    shift
done

git rev-parse --show-toplevel >/dev/null 2>&1 || die "rode dentro de um repositório git"
cd "$(git rev-parse --show-toplevel)"
[[ -n "$APP" ]] || APP="$(basename "$PWD" | tr '[:upper:]_' '[:lower:]-')"
JENKINS="${JENKINS%/}"

[[ "$TENANT" =~ ^[a-z][a-z0-9]{1,9}$ ]] || die "--tenant obrigatório (2-10 minúsculas/dígitos, o nome recebido do admin)"
[[ "$APP" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || die "nome do app inválido: '$APP' (use --app; minúsculas, dígitos e hífen, até 31)"
[[ "$PORT" =~ ^[0-9]{4,5}$ ]] && ((PORT >= 1024 && PORT <= 65535)) || die "--port inválida: $PORT (1024-65535)"
[[ "$HEALTH" =~ ^/[A-Za-z0-9/_.-]*$ ]] || die "--health inválido: $HEALTH"
git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || die "--branch inválida: $BRANCH"
[[ "$JENKINS" =~ ^https?://[a-z0-9.-]+(:[0-9]+)?$ ]] || die "--jenkins inválida: $JENKINS"

printf 'Preparando %s (tenant %s, app %s)\n' "$PWD" "$TENANT" "$APP"

# --- Jenkinsfile ----------------------------------------------------------------------
if [[ -e Jenkinsfile && $FORCE == 0 ]]; then
    warn "Jenkinsfile já existe: mantido (use --force para trocar pelo da plataforma)"
else
    cat >Jenkinsfile <<EOF
// Pipeline da plataforma (Shared Library "platform", repo devops-platform/jenkins-lib).
// Modo tenant: build e testes no agente do tenant ($TENANT); a branch $BRANCH publica a
// imagem no registry do tenant. O link público sai por make deploy-request (aprovação do admin).
@Library('platform') _

appPipeline(
    name: '$APP',
    tenant: '$TENANT',
    deployBranch: '$BRANCH',
)
EOF
    info "Jenkinsfile criado"
fi

# --- scripts/platform.sh ----------------------------------------------------------------
if [[ -e scripts/platform.sh && $FORCE == 0 ]]; then
    warn "scripts/platform.sh já existe: mantido (use --force para atualizar)"
else
    mkdir -p scripts
    src='{{cookiecutter.project_slug}}/scripts/platform.sh'
    here="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || true)"
    tmp="$(mktemp)"
    if [[ -n "$here" && -f "$here/$src" ]]; then
        cp "$here/$src" "$tmp"
    else
        curl -fsSL "$TEMPLATE_RAW/%7B%7Bcookiecutter.project_slug%7D%7D/scripts/platform.sh" -o "$tmp" \
            || die "não consegui baixar o platform.sh de $TEMPLATE_RAW"
    fi
    sed -e "s#{{ cookiecutter.jenkins_url }}#$JENKINS#g" \
        -e "s#{{ cookiecutter.tenant }}#$TENANT#g" \
        -e "s#{{ cookiecutter.project_slug }}#$APP#g" \
        -e "s#{{ cookiecutter.deploy_branch }}#$BRANCH#g" \
        -e "s#{{ cookiecutter.app_port }}#$PORT#g" \
        -e "s#{{ cookiecutter.health_path }}#$HEALTH#g" \
        "$tmp" >scripts/platform.sh
    rm -f "$tmp"
    grep -q '{{' scripts/platform.sh && die "scripts/platform.sh ficou com variáveis do template sem substituir"
    chmod 755 scripts/platform.sh
    info "scripts/platform.sh criado"
fi

# --- Makefile -----------------------------------------------------------------------------
marker='# --- Jenkins da plataforma (adopt.sh) ---'
if [[ -f Makefile ]] && grep -qF "$marker" Makefile; then
    info "Makefile já tem os alvos da plataforma"
else
    for t in jenkins-login jenkins-build jenkins-status deploy-request logs undeploy; do
        if [[ -f Makefile ]] && grep -qE "^$t:" Makefile; then
            die "o Makefile já tem um alvo '$t'; renomeie o seu ou adicione os alvos à mão (ver README do app-template)"
        fi
    done
    {
        [[ -s Makefile ]] && printf '\n'
        printf '%s\n' "$marker"
        printf '.PHONY: jenkins-login jenkins-build jenkins-status deploy-request logs undeploy\n\n'
        printf 'jenkins-login:\n\t@scripts/platform.sh login\n\n'
        printf 'jenkins-build:\n\t@scripts/platform.sh build\n\n'
        printf 'jenkins-status:\n\t@scripts/platform.sh status\n\n'
        printf 'deploy-request:\n\t@TAG=$(TAG) scripts/platform.sh deploy-request\n\n'
        printf 'logs:\n\t@LINES=$(LINES) scripts/platform.sh logs\n\n'
        printf 'undeploy:\n\t@scripts/platform.sh undeploy\n'
    } >>Makefile
    info "alvos da plataforma adicionados ao Makefile"
fi

# --- docker/Dockerfile ----------------------------------------------------------------------
if [[ ! -f docker/Dockerfile ]]; then
    if [[ -f Dockerfile ]]; then
        mkdir -p docker
        git mv Dockerfile docker/Dockerfile 2>/dev/null || mv Dockerfile docker/Dockerfile
        info "Dockerfile movido para docker/Dockerfile (o contexto do build continua sendo a raiz)"
    else
        warn "sem Dockerfile: crie docker/Dockerfile (estágio 'runtime', HEALTHCHECK e USER não-root; exemplo no README do app-template)"
    fi
fi

if [[ -f docker/Dockerfile ]]; then
    df=docker/Dockerfile
    if ! grep -qiE '^[[:space:]]*FROM[[:space:]].*[[:space:]]AS[[:space:]]+runtime[[:space:]]*$' "$df"; then
        last="$(grep -niE '^[[:space:]]*FROM[[:space:]]' "$df" | tail -1 | cut -d: -f1 || true)"
        if [[ -n "$last" ]] && ! sed -n "${last}p" "$df" | grep -qiE '[[:space:]]AS[[:space:]]'; then
            sed -i "${last}s/[[:space:]]*\$/ AS runtime/" "$df"
            info "último estágio do Dockerfile nomeado 'runtime'"
        else
            warn "o último FROM do docker/Dockerfile já tem nome: renomeie-o para 'runtime' (é a imagem que vai para o ar)"
        fi
    fi
    grep -qiE '^[[:space:]]*HEALTHCHECK[[:space:]]+(--[a-z-]+=[^ ]+[[:space:]]+)*CMD' "$df" \
        || warn "falta HEALTHCHECK no docker/Dockerfile (ex.: chamar http://127.0.0.1:$PORT$HEALTH e falhar se não vier 200)"
    user="$(grep -iE '^[[:space:]]*USER[[:space:]]' "$df" | tail -1 | awk '{print $2}' || true)"
    case "$user" in
        "" | root | 0 | root:* | 0:*) warn "a imagem roda como root: adicione um usuário (ex.: RUN useradd -m app) e USER app no fim do Dockerfile" ;;
    esac
    grep -qiE '^[[:space:]]*FROM[[:space:]].*[[:space:]]AS[[:space:]]+test[[:space:]]*$' "$df" \
        || info "opcional: um estágio 'test' (lint + testes) faz o build falhar quando os testes falham"
fi

cat <<EOF

Pronto. Próximos passos:
  1. revise: git status && git diff
  2. commit e push na $BRANCH
  3. no seu repo, webhook de push para a URL que o admin mandou (content type application/json)
  4. make jenkins-login   (uma vez)   →   make jenkins-status   →   make deploy-request
EOF
((WARNINGS == 0)) || printf '\nAtenção: %d item(ns) acima marcados com "!" precisam de ajuste antes do deploy.\n' "$WARNINGS"
