#!/usr/bin/env bash
# Teste ponta a ponta do template cookiecutter no Docker do servidor.
#
# Para cada variacao: gera o projeto, valida compose e Dockerfile, roda o stage
# `test`, faz o build do `runtime`, sobe o container numa rede descartavel (sem
# porta publicada), espera `healthy` e chama o health_path direto e via um
# Traefik descartavel usando as labels do docker-compose.yml.
#
# Nao toca em 80/443, na rede `proxy` nem nos containers `traefik`/`jenkins`.
# Tudo o que e criado leva o sufixo do teste e e removido no trap EXIT.
#
# Uso: tests/test_template.sh   (KEEP_WORKDIR=1 preserva os projetos gerados)
set -Eeuo pipefail

SUFFIX="${TEST_SUFFIX:-t0019}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="${REPO_ROOT}"
WRAPPER="${REPO_ROOT}/scripts/cookiecutter.sh"
NETWORK="tpl-net-${SUFFIX}"
TRAEFIK="tpl-traefik-${SUFFIX}"
# Imagens auxiliares com versao fixa; as que este teste baixar sao removidas no final.
TRAEFIK_IMAGE="${TRAEFIK_IMAGE:-traefik:v3.7.13}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.22.0}"
SHELLCHECK_IMAGE="${SHELLCHECK_IMAGE:-koalaman/shellcheck:v0.11.0}"
YAMLLINT_IMAGE="${YAMLLINT_IMAGE:-cytopia/yamllint@sha256:3e9eb827ab2b12a5ea5f49d4257bb3aca94bba9f1ba427c8bc7f2456385a5204}"
IMAGE_REPO="tpl-${SUFFIX}"
# Mesma imagem usada pelo wrapper no modo container.
COOKIECUTTER_IMAGE="${COOKIECUTTER_IMAGE:-python:3.14-slim}"
export COOKIECUTTER_IMAGE
VERSION="ver-${SUFFIX}-$$"
WORKDIR="$(mktemp -d "/tmp/tpl-${SUFFIX}.XXXXXX")"

# Cleanup so remove o que este teste criou: se o preflight acusar recurso de
# outra execucao, nada dela e tocado.
STARTED_PROJECTS=()
CREATED_IMAGES=()
PULLED_IMAGES=()
NETWORK_CREATED=0
TRAEFIK_CREATED=0

log() { printf '\n==> %s\n' "$*"; }
fail() {
  printf '\nFALHA: %s\n' "$*" >&2
  exit 1
}

on_error() {
  local status=$? line=$1
  printf '\nFALHA: comando com status %s na linha %s\n' "${status}" "${line}" >&2
}
trap 'on_error ${LINENO}' ERR

cleanup() {
  local status=$?
  set +e
  trap - ERR
  log 'Limpeza'
  local dir
  for dir in "${STARTED_PROJECTS[@]}"; do
    (cd "${dir}" && PROXY_NETWORK="${NETWORK}" APP_IMAGE=unused docker compose -p "$(basename "${dir}")" down --remove-orphans --volumes >/dev/null 2>&1)
  done
  ((TRAEFIK_CREATED)) && docker rm -f "${TRAEFIK}" >/dev/null 2>&1
  ((NETWORK_CREATED)) && docker network rm "${NETWORK}" >/dev/null 2>&1
  if ((${#CREATED_IMAGES[@]})); then
    docker image rm -f "${CREATED_IMAGES[@]}" >/dev/null 2>&1
  fi
  # Sem -f: se outra execucao estiver usando a imagem, ela fica.
  if ((${#PULLED_IMAGES[@]})); then
    docker image rm "${PULLED_IMAGES[@]}" >/dev/null 2>&1
  fi
  if [[ "${KEEP_WORKDIR:-0}" == 1 ]]; then
    echo "projetos preservados em ${WORKDIR}"
  else
    rm -rf "${WORKDIR}"
  fi
  if ((status == 0)); then
    printf '\nOK: template validado\n'
  else
    printf '\nFALHOU (status %s)\n' "${status}" >&2
  fi
  exit "${status}"
}
trap cleanup EXIT

# --- preflight ---------------------------------------------------------------
preflight() {
  log 'Preflight'
  local cmd
  for cmd in docker python3; do
    command -v "${cmd}" >/dev/null || fail "comando ausente: ${cmd}"
  done
  docker info >/dev/null 2>&1 || fail 'docker daemon inacessivel'
  docker compose version >/dev/null 2>&1 || fail 'plugin docker compose (v2) ausente'
  docker buildx version >/dev/null 2>&1 || fail 'plugin buildx ausente (necessario para --check)'
  [[ -x "${WRAPPER}" ]] || fail "wrapper nao executavel: ${WRAPPER}"
  [[ -f "${TEMPLATE_DIR}/cookiecutter.json" ]] || fail 'cookiecutter.json ausente'

  docker network inspect "${NETWORK}" >/dev/null 2>&1 && fail "rede ${NETWORK} ja existe (outro teste rodando?)"
  docker container inspect "${TRAEFIK}" >/dev/null 2>&1 && fail "container ${TRAEFIK} ja existe"
  local slug
  for slug in "tpl-default-${SUFFIX}" "tpl-curl-${SUFFIX}" "tpl-wget-${SUFFIX}"; do
    docker container inspect "${slug}" >/dev/null 2>&1 && fail "container ${slug} ja existe"
  done

  local image
  for image in "${TRAEFIK_IMAGE}" "${CURL_IMAGE}" "${SHELLCHECK_IMAGE}" "${YAMLLINT_IMAGE}" "${COOKIECUTTER_IMAGE}"; do
    if ! docker image inspect "${image}" >/dev/null 2>&1; then
      docker pull -q "${image}" >/dev/null
      PULLED_IMAGES+=("${image}")
    fi
  done
  return 0
}

# --- lint ----------------------------------------------------------------------
lint_scripts() {
  log 'shellcheck nos scripts'
  docker run --rm -v "${REPO_ROOT}:/mnt:ro" -w /mnt "${SHELLCHECK_IMAGE}" \
    scripts/cookiecutter.sh tests/test_template.sh
}

lint_yaml() {
  local dir=$1
  log "yamllint em $(basename "${dir}")"
  docker run --rm -v "${dir}:/data:ro" -w /data "${YAMLLINT_IMAGE}" \
    -d '{extends: relaxed, rules: {line-length: disable}}' docker-compose.yml .pre-commit-config.yaml
}

# --- helpers -----------------------------------------------------------------
generate() {
  "${WRAPPER}" --no-input --output-dir "${WORKDIR}" "${TEMPLATE_DIR}" "$@"
}

# Argumentos: descricao, padrao esperado na saida, chave=valor do cookiecutter.
expect_generation_failure() {
  local label=$1 pattern=$2
  shift 2
  if generate "$@" >"${WORKDIR}/neg.log" 2>&1; then
    fail "valor invalido aceito (${label})"
  fi
  grep -q "${pattern}" "${WORKDIR}/neg.log" || fail "falhou sem a mensagem '${pattern}' (${label}): $(tail -3 "${WORKDIR}/neg.log")"
  echo "rejeitado como esperado: ${label}"
}

# Faz GET dentro da rede de teste e confere status 200 e o JSON esperado.
# Argumentos: descricao, chave=valor esperados no JSON, depois os args do curl.
http_check() {
  local what=$1 expected=$2
  shift 2
  local out
  for _ in $(seq 1 20); do
    if out="$(docker run --rm --network "${NETWORK}" "${CURL_IMAGE}" -sS --max-time 5 -w '\n%{http_code}' "$@" 2>&1)"; then
      if [[ "${out##*$'\n'}" == 200 ]]; then
        break
      fi
    fi
    sleep 1
  done
  [[ "${out##*$'\n'}" == 200 ]] || fail "${what}: esperado HTTP 200, obtido: ${out}"
  local body="${out%$'\n'*}"
  python3 - "${body}" "${expected}" <<'PY' || fail "${what}: corpo inesperado: ${body}"
import json, sys
body = json.loads(sys.argv[1])
for pair in sys.argv[2].split(','):
    key, value = pair.split('=', 1)
    assert str(body.get(key)) == value, (key, body.get(key), value)
PY
  echo "${what}: 200 ${body}"
}

wait_healthy() {
  local container=$1 status=''
  for _ in $(seq 1 30); do
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${container}")"
    case "${status}" in
      healthy)
        echo "${container}: healthy"
        return 0
        ;;
      none) fail "${container} sem healthcheck" ;;
    esac
    sleep 2
  done
  docker logs "${container}" >&2 || true
  fail "${container} nao ficou healthy (status: ${status})"
}

start_traefik() {
  log "Traefik descartavel (${TRAEFIK_IMAGE}) restrito a ${NETWORK}"
  # Sem portas publicadas. O provider so enxerga containers cuja label
  # traefik.docker.network aponta para a rede de teste.
  docker run -d --name "${TRAEFIK}" --network "${NETWORK}" \
    --label "devops-platform.test=${SUFFIX}" \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    "${TRAEFIK_IMAGE}" \
    --log.level=INFO \
    --ping=true \
    --entrypoints.ping.address=:8082 \
    --ping.entrypoint=ping \
    --entrypoints.websecure.address=:8443 \
    --providers.docker=true \
    --providers.docker.exposedbydefault=false \
    --providers.docker.network="${NETWORK}" \
    --providers.docker.constraints="Label(\`traefik.docker.network\`,\`${NETWORK}\`)" >/dev/null
  TRAEFIK_CREATED=1

  for _ in $(seq 1 30); do
    if docker run --rm --network "${NETWORK}" "${CURL_IMAGE}" -fsS --max-time 2 "http://${TRAEFIK}:8082/ping" >/dev/null 2>&1; then
      echo 'traefik: ping ok'
      return 0
    fi
    sleep 1
  done
  docker logs "${TRAEFIK}" >&2 || true
  fail 'traefik nao respondeu ao /ping'
}

# --- caso completo -----------------------------------------------------------
# Argumentos: slug port health_path host versao_esperada(yes|no) [chave=valor do cookiecutter...]
run_case() {
  local slug=$1 port=$2 health=$3 host=$4 expects_version=$5
  shift 5
  local dir="${WORKDIR}/${slug}"
  local test_image="${IMAGE_REPO}/${slug}:test"
  local runtime_image="${IMAGE_REPO}/${slug}:runtime"

  log "[${slug}] geracao"
  generate project_slug="${slug}" "$@"
  [[ -d "${dir}" ]] || fail "pasta ${dir} nao foi criada"
  [[ ! -e "${dir}/Jenkinsfile" ]] || echo 'Jenkinsfile presente (mantido pelo pipeline)'

  log "[${slug}] docker compose config -q sem variaveis de ambiente"
  local compose_err
  compose_err="$(cd "${dir}" && env -i PATH="${PATH}" HOME="${HOME}" docker compose config -q 2>&1)" \
    || fail "compose config falhou: ${compose_err}"
  [[ -z "${compose_err}" ]] || fail "compose config emitiu avisos: ${compose_err}"
  local rendered
  rendered="$(cd "${dir}" && env -i PATH="${PATH}" HOME="${HOME}" docker compose config --format json)"
  python3 - "${rendered}" "${slug}" "${port}" "${host}" <<'PY' || fail 'compose renderizado fora do contrato'
import json, sys
cfg, slug, port, host = json.loads(sys.argv[1]), *sys.argv[2:]
app = cfg['services']['app']
labels = app['labels']
assert app['container_name'] == slug
assert app['image'] == f'gru.ocir.io/grun5vjqis7z/{slug}:latest', app['image']
assert app['pull_policy'] == 'missing'
assert 'ports' not in app, 'servico publica portas'
assert app['expose'] == [port]
assert 'healthcheck' in app
net = cfg['networks']['proxy']
assert net['name'] == 'proxy' and net['external'] is True, net
expected = {
    'traefik.enable': 'true',
    'traefik.docker.network': 'proxy',
    f'traefik.http.routers.{slug}.rule': f'Host(`{host}`)',
    f'traefik.http.routers.{slug}.entrypoints': 'websecure',
    f'traefik.http.routers.{slug}.tls.certresolver': 'letsencrypt',
    f'traefik.http.services.{slug}.loadbalancer.server.port': port,
}
for key, value in expected.items():
    assert labels.get(key) == value, (key, labels.get(key), value)
PY
  lint_yaml "${dir}"

  log "[${slug}] docker build --check"
  docker build --check -f "${dir}/docker/Dockerfile" "${dir}"

  log "[${slug}] build --target test"
  docker build --target test -t "${test_image}" -f "${dir}/docker/Dockerfile" "${dir}"
  CREATED_IMAGES+=("${test_image}")

  log "[${slug}] build --target runtime"
  docker build --target runtime --build-arg APP_VERSION="${VERSION}" \
    -t "${runtime_image}" -f "${dir}/docker/Dockerfile" "${dir}"
  CREATED_IMAGES+=("${runtime_image}")

  local user exposed has_health
  user="$(docker image inspect --format '{{.Config.User}}' "${runtime_image}")"
  exposed="$(docker image inspect --format '{{range $p, $v := .Config.ExposedPorts}}{{$p}} {{end}}' "${runtime_image}")"
  has_health="$(docker image inspect --format '{{if .Config.Healthcheck}}yes{{end}}' "${runtime_image}")"
  [[ -n "${user}" && "${user}" != root && "${user}" != 0 ]] || fail "imagem roda como root (User=${user})"
  [[ " ${exposed} " == *" ${port}/tcp "* ]] || fail "EXPOSE esperado ${port}/tcp, obtido: ${exposed}"
  [[ "${has_health}" == yes ]] || fail 'imagem sem HEALTHCHECK'
  echo "imagem: user=${user} expose=${exposed}healthcheck=${has_health}"

  log "[${slug}] compose up na rede ${NETWORK}"
  STARTED_PROJECTS+=("${dir}")
  (cd "${dir}" && APP_IMAGE="${runtime_image}" PROXY_NETWORK="${NETWORK}" \
    docker compose -p "${slug}" up -d --wait --wait-timeout 90)
  wait_healthy "${slug}"
  [[ -z "$(docker port "${slug}")" ]] || fail "${slug} publicou portas: $(docker port "${slug}")"

  # O app do template sempre devolve a versao; health_expects_version so muda
  # a validacao do pipeline (legados).
  local expected="status=ok,version=${VERSION}"
  echo "health_expects_version=${expects_version}"

  http_check "[${slug}] direto ${health}" "${expected}" "http://${slug}:${port}${health}"
  http_check "[${slug}] via traefik https://${host}${health}" "${expected}" \
    -k --connect-to "${host}:443:${TRAEFIK}:8443" "https://${host}${health}"

  # Host desconhecido nao pode cair na app.
  local code
  code="$(docker run --rm --network "${NETWORK}" "${CURL_IMAGE}" -sk -o /dev/null -w '%{http_code}' \
    --connect-to "nao-existe.invalid:443:${TRAEFIK}:8443" "https://nao-existe.invalid${health}")"
  [[ "${code}" == 404 ]] || fail "host desconhecido devolveu ${code} (esperado 404 do traefik)"
  echo "host desconhecido: 404"
}

# --- execucao ------------------------------------------------------------------
preflight
lint_scripts

log 'valores invalidos precisam abortar a geracao'
expect_generation_failure 'slug com maiuscula/underscore' 'ERRO:' project_slug=Bad_Slug
expect_generation_failure 'domain sem ponto' 'ERRO:' domain=localhost
expect_generation_failure 'porta fora do intervalo' 'ERRO:' app_port=70000
expect_generation_failure 'health_path sem barra' 'ERRO:' health_path=health
# choices sao validadas pelo proprio cookiecutter antes do hook
expect_generation_failure 'healthcheck_tool desconhecido' 'choice variable' healthcheck_tool=nc
expect_generation_failure 'modo tenant sem tenant' 'tenant invalido' platform_mode=tenant
expect_generation_failure 'tenant com nome invalido' 'tenant invalido' platform_mode=tenant tenant=Amigo_1
expect_generation_failure 'tenant no modo platform' 'tenant so faz sentido' tenant=amigo
expect_generation_failure 'slug longo no modo tenant' 'project_slug invalido no modo tenant' \
  platform_mode=tenant tenant=amigo project_slug=um-slug-bem-comprido-demais-para-tenant
[[ -z "$(find "${WORKDIR}" -mindepth 1 -maxdepth 1 ! -name neg.log)" ]] || fail 'geracao rejeitada deixou arquivos para tras'

log 'slug derivado do project_name'
generate project_name="Aplicação Teste ${SUFFIX}" >/dev/null
[[ -d "${WORKDIR}/aplicacao-teste-${SUFFIX}" ]] || fail "slug derivado inesperado: $(ls "${WORKDIR}")"
echo "ok: aplicacao-teste-${SUFFIX}"

log 'wrapper no modo container gera o mesmo resultado que o modo padrao'
mkdir -p "${WORKDIR}/via-docker"
COOKIECUTTER_MODE=docker "${WRAPPER}" --no-input --output-dir "${WORKDIR}/via-docker" "${TEMPLATE_DIR}" \
  project_name="Aplicação Teste ${SUFFIX}"
diff -r "${WORKDIR}/aplicacao-teste-${SUFFIX}" "${WORKDIR}/via-docker/aplicacao-teste-${SUFFIX}" \
  || fail 'saida do modo docker difere'
echo 'ok: saidas identicas'

docker network create --label "devops-platform.test=${SUFFIX}" "${NETWORK}" >/dev/null
NETWORK_CREATED=1
start_traefik

# dominio padrao lido do proprio template, para o teste nao depender dele
DEFAULT_DOMAIN=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['domain'])" "${TEMPLATE_DIR}/cookiecutter.json")

# 1) padroes do template (python no healthcheck)
run_case "tpl-default-${SUFFIX}" 8000 /health "tpl-default-${SUFFIX}.${DEFAULT_DOMAIN}" yes

# 2) curl, outra porta, outro health_path, outro host e .env opcional presente
run_case "tpl-curl-${SUFFIX}" 8080 /healthz "api-${SUFFIX}.${SUFFIX}.test" yes \
  healthcheck_tool=curl app_port=8080 health_path=/healthz subdomain="api-${SUFFIX}" \
  domain="${SUFFIX}.test" deploy_branch=main
log "[tpl-curl-${SUFFIX}] env_file opcional"
printf 'APP_NAME=Nome via env %s\n' "${SUFFIX}" >"${WORKDIR}/tpl-curl-${SUFFIX}/.env"
(cd "${WORKDIR}/tpl-curl-${SUFFIX}" && APP_IMAGE="${IMAGE_REPO}/tpl-curl-${SUFFIX}:runtime" PROXY_NETWORK="${NETWORK}" \
  docker compose -p "tpl-curl-${SUFFIX}" up -d --wait --wait-timeout 90 --force-recreate)
http_check "[tpl-curl-${SUFFIX}] / com APP_NAME do .env" "name=Nome via env ${SUFFIX},version=${VERSION}" \
  -k --connect-to "api-${SUFFIX}.${SUFFIX}.test:443:${TRAEFIK}:8443" "https://api-${SUFFIX}.${SUFFIX}.test/"

# 3) wget, healthcheck na raiz e legado sem versao no contrato
run_case "tpl-wget-${SUFFIX}" 8000 / "tpl-wget-${SUFFIX}.${DEFAULT_DOMAIN}" no \
  healthcheck_tool=wget health_path=/ health_expects_version=no

log 'Jenkinsfile e renovate.json do modo platform'
jf="${WORKDIR}/tpl-default-${SUFFIX}/Jenkinsfile"
grep -q "^@Library('platform') _$" "${jf}" || fail 'Jenkinsfile sem @Library platform'
grep -q "name: 'tpl-default-${SUFFIX}'," "${jf}" || fail 'Jenkinsfile sem name'
grep -q "host: 'tpl-default-${SUFFIX}.${DEFAULT_DOMAIN}'," "${jf}" || fail 'Jenkinsfile sem host'
grep -q 'tenant:' "${jf}" && fail 'Jenkinsfile do modo platform com tenant'
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['extends']==['local>thentsation/devops-platform:renovate/default'], d" \
  "${WORKDIR}/tpl-default-${SUFFIX}/renovate.json" || fail 'renovate.json do modo platform inesperado'
[[ ! -e "${WORKDIR}/tpl-default-${SUFFIX}/scripts" ]] || fail 'modo platform gerou scripts/platform.sh'
[[ ! -e "${WORKDIR}/tpl-default-${SUFFIX}/.github" ]] || fail 'template ainda gera .github/'
echo 'ok: Jenkinsfile chama appPipeline com host; renovate usa o preset da plataforma; sem .github/'

log 'modo tenant'
tslug="tpl-tenant-${SUFFIX}"
generate platform_mode=tenant tenant=demo project_name="${tslug}" >/dev/null
tdir="${WORKDIR}/${tslug}"
grep -q "tenant: 'demo'," "${tdir}/Jenkinsfile" || fail 'Jenkinsfile do tenant sem tenant'
grep -q 'host:' "${tdir}/Jenkinsfile" && fail 'Jenkinsfile do tenant com host'
[[ -x "${tdir}/scripts/platform.sh" ]] || fail 'scripts/platform.sh ausente ou sem permissao de execucao'
grep -q '^TENANT="demo"$' "${tdir}/scripts/platform.sh" || fail 'platform.sh sem o tenant'
grep -q 'https://jenkins.137-131-175-7.sslip.io' "${tdir}/scripts/platform.sh" || fail 'platform.sh sem a URL do Jenkins'
grep -q '^deploy-request:' "${tdir}/Makefile" || fail 'Makefile sem deploy-request'
grep -q "127.0.0.1:8000:8000" "${tdir}/docker-compose.yml" || fail 'compose local do tenant sem porta em 127.0.0.1'
grep -q 'traefik' "${tdir}/docker-compose.yml" && fail 'compose do tenant com labels do traefik'
grep -q "${tslug}-demo.${DEFAULT_DOMAIN}" "${tdir}/README.pt-br.md" || fail 'README do tenant sem a URL publica'
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['extends']==['config:recommended'], d" \
  "${tdir}/renovate.json" || fail 'renovate.json do tenant inesperado'
(cd "${tdir}" && docker compose config -q) || fail 'compose local do tenant invalido'
docker run --rm -v "${tdir}:/mnt:ro" -w /mnt "${SHELLCHECK_IMAGE}" scripts/platform.sh || fail 'shellcheck no platform.sh'
(cd "${tdir}" && make -n jenkins-login deploy-request logs undeploy >/dev/null) || fail 'alvos do Makefile do tenant'
docker build --target test -q -f "${tdir}/docker/Dockerfile" "${tdir}" >/dev/null || fail 'stage test do tenant falhou'
echo 'ok: Jenkinsfile com tenant, CLI, Makefile, compose local e stage test'

log 'stage test precisa falhar quando um teste falha'
broken="${WORKDIR}/broken"
cp -r "${WORKDIR}/tpl-default-${SUFFIX}" "${broken}"
printf '\n\ndef test_quebrado() -> None:\n    assert len([]) == 1\n' >>"${broken}/tests/test_main.py"
if docker build --target test -q -f "${broken}/docker/Dockerfile" "${broken}" >/dev/null 2>&1; then
  fail 'build --target test passou com teste quebrado'
fi
echo 'ok: build do stage test falhou como esperado'
