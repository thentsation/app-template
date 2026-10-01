"""Checagens de sanidade no projeto recem-criado (roda dentro da pasta dele).

Falha com exit 1 se faltar arquivo, se sobrar marcacao do Jinja ou se algum
YAML/TOML nao for parseavel.
"""

import sys
from pathlib import Path

EXPECTED_FILES = [
    '.dockerignore',
    '.env.example',
    '.gitignore',
    '.pre-commit-config.yaml',
    'CHANGELOG.md',
    'Makefile',
    'README.md',
    'README.pt-br.md',
    'config/requirements-dev.txt',
    'config/requirements.lock',
    'config/requirements.txt',
    'docker-compose.yml',
    'docker/Dockerfile',
    'pyproject.toml',
    'pytest.ini',
    'src/__init__.py',
    'src/config.py',
    'src/main.py',
    'src/models.py',
    'src/routes/__init__.py',
    'src/routes/meta.py',
    'tests/conftest.py',
    'tests/test_config.py',
    'tests/test_main.py',
]

# O Jenkinsfile e mantido a parte e pode conter sintaxe propria.
SKIP_RENDER_CHECK = {'Jenkinsfile'}
# Montado por concatenacao para o proprio hook nao ser interpretado pelo Jinja.
JINJA_MARKERS = tuple('{' + c for c in ('{', '%', '#'))


def project_files(root: Path) -> list[Path]:
    return [p for p in root.rglob('*') if p.is_file() and '.git' not in p.parts]


def check_expected(root: Path) -> list[str]:
    return [f'arquivo esperado ausente: {name}' for name in EXPECTED_FILES if not (root / name).is_file()]


def check_rendered(root: Path) -> list[str]:
    errors = []
    for path in project_files(root):
        rel = path.relative_to(root).as_posix()
        if rel in SKIP_RENDER_CHECK:
            continue
        try:
            text = path.read_text(encoding='utf-8')
        except UnicodeDecodeError:
            continue
        for marker in JINJA_MARKERS:
            if marker in text:
                errors.append(f'marcacao {marker!r} sobrando em {rel}')
    return errors


def check_parseable(root: Path) -> list[str]:
    errors = []
    try:
        import yaml
    except ImportError:
        print('aviso: PyYAML indisponivel, YAML nao validado', file=sys.stderr)
    else:
        for path in project_files(root):
            if path.suffix in ('.yml', '.yaml'):
                try:
                    yaml.safe_load(path.read_text(encoding='utf-8'))
                except yaml.YAMLError as exc:
                    errors.append(f'YAML invalido em {path.relative_to(root)}: {exc}')

    try:
        import tomllib
    except ImportError:
        print('aviso: tomllib indisponivel, pyproject.toml nao validado', file=sys.stderr)
    else:
        try:
            tomllib.loads((root / 'pyproject.toml').read_text(encoding='utf-8'))
        except (OSError, tomllib.TOMLDecodeError) as exc:
            errors.append(f'pyproject.toml invalido: {exc}')
    return errors


def check_identity(root: Path) -> list[str]:
    compose = (root / 'docker-compose.yml').read_text(encoding='utf-8')
    slug = '{{ cookiecutter.project_slug }}'
    if f'container_name: {slug}\n' not in compose:
        return [f'docker-compose.yml sem container_name: {slug}']
    return []


def main() -> int:
    root = Path.cwd()
    errors = check_expected(root)
    if not errors:
        errors = check_rendered(root) + check_parseable(root) + check_identity(root)
    for error in errors:
        print(f'ERRO: {error}', file=sys.stderr)
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
