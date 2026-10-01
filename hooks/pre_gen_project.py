"""Valida as respostas do cookiecutter antes de criar qualquer arquivo.

Qualquer erro aborta a geracao com exit 1 e uma mensagem por campo.
"""

import re
import sys

SLUG_RE = re.compile(r'^[a-z][a-z0-9-]{0,61}[a-z0-9]$')
LABEL_RE = re.compile(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$')
HEALTH_PATH_RE = re.compile(r'^/[A-Za-z0-9._~/-]*$')
BRANCH_RE = re.compile(r'^[A-Za-z0-9._/-]+$')
PYTHON_RE = re.compile(r'^3\.[0-9]+$')

values = {
    'project_name': r"""{{ cookiecutter.project_name }}""",
    'project_slug': r"""{{ cookiecutter.project_slug }}""",
    'domain': r"""{{ cookiecutter.domain }}""",
    'subdomain': r"""{{ cookiecutter.subdomain }}""",
    'app_port': r"""{{ cookiecutter.app_port }}""",
    'health_path': r"""{{ cookiecutter.health_path }}""",
    'health_expects_version': r"""{{ cookiecutter.health_expects_version }}""",
    'healthcheck_tool': r"""{{ cookiecutter.healthcheck_tool }}""",
    'deploy_branch': r"""{{ cookiecutter.deploy_branch }}""",
    'python_version': r"""{{ cookiecutter.python_version }}""",
    'registry': r"""{{ cookiecutter.registry }}""",
    'registry_namespace': r"""{{ cookiecutter.registry_namespace }}""",
    'proxy_network': r"""{{ cookiecutter.proxy_network }}""",
}


def is_hostname(value: str, min_labels: int) -> bool:
    if len(value) > 253:
        return False
    labels = value.split('.')
    return len(labels) >= min_labels and all(LABEL_RE.match(label) for label in labels)


def validate(v: dict[str, str]) -> list[str]:
    errors = []

    if not v['project_name'].strip() or re.search(r'["\'\\]', v['project_name']):
        errors.append('project_name vazio ou com aspas/barra invertida')

    if not SLUG_RE.match(v['project_slug']):
        errors.append(
            f'project_slug invalido: {v["project_slug"]!r} '
            '(2-63 caracteres, minusculas, digitos e hifen, comecando com letra)'
        )

    if not is_hostname(v['domain'], min_labels=2):
        errors.append(f'domain invalido: {v["domain"]!r} (ex.: example.com, so minusculas)')

    if not is_hostname(v['subdomain'], min_labels=1):
        errors.append(f'subdomain invalido: {v["subdomain"]!r}')

    port = v['app_port']
    if not port.isdigit() or not 1 <= int(port) <= 65535:
        errors.append(f'app_port invalida: {port!r} (inteiro entre 1 e 65535)')

    if not HEALTH_PATH_RE.match(v['health_path']) or '//' in v['health_path']:
        errors.append(f'health_path invalido: {v["health_path"]!r} (ex.: /health)')

    if v['health_expects_version'] not in ('yes', 'no'):
        errors.append('health_expects_version deve ser yes ou no')

    if v['healthcheck_tool'] not in ('python', 'curl', 'wget'):
        errors.append('healthcheck_tool deve ser python, curl ou wget')

    branch = v['deploy_branch']
    if not BRANCH_RE.match(branch) or branch.startswith(('/', '-')) or '..' in branch:
        errors.append(f'deploy_branch invalida: {branch!r}')

    if not PYTHON_RE.match(v['python_version']):
        errors.append(f'python_version invalida: {v["python_version"]!r} (ex.: 3.14)')

    if not is_hostname(v['registry'], min_labels=2):
        errors.append(f'registry invalido: {v["registry"]!r}')

    if not LABEL_RE.match(v['registry_namespace']):
        errors.append(f'registry_namespace invalido: {v["registry_namespace"]!r}')

    if not re.match(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$', v['proxy_network']):
        errors.append(f'proxy_network invalida: {v["proxy_network"]!r}')

    return errors


if __name__ == '__main__':
    problems = validate(values)
    for problem in problems:
        print(f'ERRO: {problem}', file=sys.stderr)
    sys.exit(1 if problems else 0)
