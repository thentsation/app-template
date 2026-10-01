#!/usr/bin/env bash
# Executa o cookiecutter repassando todos os argumentos.
# Ordem de tentativa: binario local, `uvx` e, por ultimo, um container python.
# Forcar um modo: COOKIECUTTER_MODE=local|uvx|docker.
#
# Exemplo:
#   scripts/cookiecutter.sh --no-input --output-dir /tmp/out template project_slug=minha-api
set -Eeuo pipefail

COOKIECUTTER_VERSION="${COOKIECUTTER_VERSION:-2.7.1}"
COOKIECUTTER_IMAGE="${COOKIECUTTER_IMAGE:-python:3.14-slim}"
MODE="${COOKIECUTTER_MODE:-auto}"

die() {
  echo "cookiecutter.sh: $*" >&2
  exit 1
}

find_uvx() {
  if command -v uvx >/dev/null 2>&1; then
    command -v uvx
  elif [[ -x "${HOME}/.local/bin/uvx" ]]; then
    echo "${HOME}/.local/bin/uvx"
  else
    return 1
  fi
}

run_local() {
  exec cookiecutter "$@"
}

run_uvx() {
  local uvx
  uvx="$(find_uvx)" || die 'uvx nao encontrado'
  exec "${uvx}" --from "cookiecutter==${COOKIECUTTER_VERSION}" cookiecutter "$@"
}

# No container os caminhos precisam existir com o mesmo nome absoluto:
# monta o diretorio atual, o HOME, todo argumento que seja um caminho existente
# e o diretorio de saida (-o/--output-dir), criando-o se preciso.
run_docker() {
  command -v docker >/dev/null 2>&1 || die 'nem cookiecutter, nem uvx, nem docker disponiveis'

  local -a mounts=("${PWD}" "${HOME}")
  local arg next_is_output=0
  for arg in "$@"; do
    if ((next_is_output)); then
      mkdir -p "${arg}"
      mounts+=("$(cd "${arg}" && pwd)")
      next_is_output=0
      continue
    fi
    case "${arg}" in
      -o | --output-dir)
        next_is_output=1
        continue
        ;;
      --output-dir=*)
        mkdir -p "${arg#--output-dir=}"
        mounts+=("$(cd "${arg#--output-dir=}" && pwd)")
        continue
        ;;
    esac
    if [[ -d "${arg}" ]]; then
      mounts+=("$(cd "${arg}" && pwd)")
    elif [[ -f "${arg}" ]]; then
      mounts+=("$(cd "$(dirname "${arg}")" && pwd)")
    fi
  done

  local -a volume_args=()
  local dir
  while IFS= read -r dir; do
    [[ -n "${dir}" ]] && volume_args+=(-v "${dir}:${dir}")
  done < <(printf '%s\n' "${mounts[@]}" | sort -u)

  local -a tty_args=(-i)
  [[ -t 0 && -t 1 ]] && tty_args=(-it)

  exec docker run --rm "${tty_args[@]}" \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -e PIP_DISABLE_PIP_VERSION_CHECK=1 \
    "${volume_args[@]}" \
    -w "${PWD}" \
    "${COOKIECUTTER_IMAGE}" \
    sh -c 'pip install --quiet --no-cache-dir --no-warn-script-location --user "cookiecutter==$0" >/dev/null && exec python -m cookiecutter "$@"' \
    "${COOKIECUTTER_VERSION}" "$@"
}

case "${MODE}" in
  local) run_local "$@" ;;
  uvx) run_uvx "$@" ;;
  docker) run_docker "$@" ;;
  auto)
    if command -v cookiecutter >/dev/null 2>&1; then
      run_local "$@"
    elif find_uvx >/dev/null; then
      run_uvx "$@"
    else
      run_docker "$@"
    fi
    ;;
  *) die "COOKIECUTTER_MODE invalido: ${MODE} (use local, uvx ou docker)" ;;
esac
