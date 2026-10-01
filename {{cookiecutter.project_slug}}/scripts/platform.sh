#!/usr/bin/env bash
# CLI do Jenkins da plataforma para este projeto (tenant {{ cookiecutter.tenant }}).
#
#   make jenkins-login             gera um API token (usuário e senha recebidos do admin)
#   make jenkins-build             pede um scan do repo (builds das branches novas/alteradas)
#   make jenkins-status            último build da branch atual
#   make deploy-request [TAG=sha]  pede o deploy público (o admin aprova no Jenkins)
#   make logs [LINES=200]          logs do app publicado
#   make undeploy                  tira o app do ar
#
# O token fica em ~/.config/devops-platform/<host>.env (chmod 600), nunca no repo.
set -Eeuo pipefail

JENKINS_URL="${JENKINS_URL:-{{ cookiecutter.jenkins_url }}}"
JENKINS_URL="${JENKINS_URL%/}"
TENANT="{{ cookiecutter.tenant }}"
APP="${APP:-{{ cookiecutter.project_slug }}}"
REPO="${REPO:-{{ cookiecutter.project_slug }}}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-{{ cookiecutter.deploy_branch }}}"
APP_PORT="${APP_PORT:-{{ cookiecutter.app_port }}}"
HEALTH_PATH="${HEALTH_PATH:-{{ cookiecutter.health_path }}}"

HOST="${JENKINS_URL#https://}"
HOST="${HOST#http://}"
HOST="${HOST%%/*}"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/devops-platform/$HOST.env"
FOLDER="$JENKINS_URL/job/tenants/job/$TENANT"

die() { printf 'erro: %s\n' "$*" >&2; exit 1; }
for c in curl jq; do command -v "$c" >/dev/null || die "instale o $c"; done

load_token() {
    [[ -r "$CONFIG" ]] || die "sem token: rode 'make jenkins-login' antes"
    # shellcheck disable=SC1090
    . "$CONFIG"
    [[ -n "${JENKINS_USER:-}" && -n "${JENKINS_TOKEN:-}" ]] || die "token inválido em $CONFIG: rode 'make jenkins-login'"
}

# Usuário e token via stdin (não aparecem na lista de processos).
api() {
    printf 'user = "%s:%s"\n' "$JENKINS_USER" "$JENKINS_TOKEN" | curl -K - -fsS "$@"
}

urlencode() { jq -rn --arg v "$1" '$v | @uri'; }

cmd_login() {
    local user pass jar crumb resp token
    read -r -p "Usuário do Jenkins ($HOST): " user
    read -r -s -p "Senha: " pass
    echo
    jar="$(mktemp)"
    trap 'rm -f "$jar"' RETURN
    crumb="$(printf 'user = "%s:%s"\n' "$user" "$pass" \
        | curl -K - -fsS -c "$jar" -b "$jar" "$JENKINS_URL/crumbIssuer/api/json" \
        | jq -r '.crumbRequestField + ":" + .crumb')" || die "login recusado (usuário/senha?)"
    resp="$(printf 'user = "%s:%s"\n' "$user" "$pass" \
        | curl -K - -fsS -c "$jar" -b "$jar" -X POST -H "$crumb" \
            --data-urlencode "newTokenName=cli-$(hostname -s)-$(date +%Y%m%d)" \
            "$JENKINS_URL/me/descriptorByName/jenkins.security.ApiTokenProperty/generateNewToken")" \
        || die "não consegui gerar o token"
    token="$(jq -r '.data.tokenValue' <<<"$resp")"
    [[ -n "$token" && "$token" != null ]] || die "resposta inesperada ao gerar o token"
    mkdir -p "$(dirname "$CONFIG")"
    (umask 077 && printf 'JENKINS_USER=%s\nJENKINS_TOKEN=%s\n' "$user" "$token" >"$CONFIG")
    echo "Token salvo em $CONFIG."
}

cmd_build() {
    load_token
    api -X POST -o /dev/null "$FOLDER/job/repos/job/$REPO/build?delay=0"
    echo "Scan de $REPO pedido: $FOLDER/job/repos/job/$REPO/"
}

current_branch() { git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "$DEPLOY_BRANCH"; }

cmd_status() {
    load_token
    local branch job info
    branch="$(current_branch)"
    job="$FOLDER/job/repos/job/$REPO/job/$(urlencode "$branch")"
    info="$(api "$job/lastBuild/api/json?tree=number,result,building,description,url")" \
        || die "nenhum build da branch $branch ainda (rode 'make jenkins-build')"
    jq -r '"build #\(.number): \(if .building then "rodando" else .result end)  \(.description // "")\n\(.url)"' <<<"$info"
}

# Dispara um job parametrizado e devolve a URL do build (espera sair da fila).
trigger() {
    local job="$1" headers queue exec_url i
    shift
    headers="$(api -X POST -D - -o /dev/null "$@" "$job/buildWithParameters")"
    queue="$(sed -n 's/^[Ll]ocation: *\(.*\)\r*$/\1/p' <<<"$headers" | tr -d '\r')"
    [[ -n "$queue" ]] || die "o Jenkins não devolveu o item da fila"
    for ((i = 0; i < 120; i++)); do
        exec_url="$(api "${queue%/}/api/json" | jq -r '.executable.url // empty')"
        [[ -n "$exec_url" ]] && { printf '%s\n' "$exec_url"; return 0; }
        sleep 2
    done
    die "o build continua na fila: $queue"
}

# Acompanha o console do build até terminar.
follow() {
    local url="$1" start=0 size hdr
    hdr="$(mktemp)"
    while :; do
        api -D "$hdr" "${url}logText/progressiveText?start=$start" || true
        size="$(sed -n 's/^[Xx]-[Tt]ext-[Ss]ize: *\([0-9]*\).*/\1/p' "$hdr" | tail -1)"
        start="${size:-$start}"
        grep -qi '^x-more-data: *true' "$hdr" || break
        sleep 2
    done
    rm -f "$hdr"
}

cmd_deploy_request() {
    load_token
    local tag="${TAG:-}" url
    if [[ -z "$tag" ]]; then
        # Última imagem publicada pela branch de deploy (descrição "imagem <sha>").
        tag="$(api "$FOLDER/job/repos/job/$REPO/job/$(urlencode "$DEPLOY_BRANCH")/lastSuccessfulBuild/api/json?tree=description" \
            | jq -r '.description // ""' | sed -n 's/^imagem \([0-9a-f]\{7,\}\)$/\1/p')"
        [[ -n "$tag" ]] || die "nenhuma imagem publicada pela $DEPLOY_BRANCH ainda; informe TAG=<sha>"
    fi
    url="$(trigger "$FOLDER/job/plataforma/job/deploy" \
        --data-urlencode "APP=$APP" --data-urlencode "TAG=$tag" \
        --data-urlencode "PORT=$APP_PORT" --data-urlencode "HEALTH_PATH=$HEALTH_PATH")"
    echo "Deploy de $APP:$tag pedido. Aguardando a aprovação do admin:"
    echo "  $url"
}

cmd_logs() {
    load_token
    local url
    url="$(trigger "$FOLDER/job/plataforma/job/logs" --data-urlencode "APP=$APP" \
        --data-urlencode "LINES=${LINES:-200}")"
    follow "$url"
}

cmd_undeploy() {
    load_token
    local answer url
    read -r -p "Tirar $APP do ar? [s/N] " answer
    [[ "$answer" == s || "$answer" == S ]] || { echo "cancelado"; return 0; }
    url="$(trigger "$FOLDER/job/plataforma/job/undeploy" --data-urlencode "APP=$APP")"
    echo "Undeploy pedido: $url"
}

case "${1:-}" in
    login) cmd_login ;;
    build) cmd_build ;;
    status) cmd_status ;;
    deploy-request) cmd_deploy_request ;;
    logs) cmd_logs ;;
    undeploy) cmd_undeploy ;;
    *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
