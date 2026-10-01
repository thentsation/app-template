import pytest

from config import HEALTH_PATH, Settings


def test_settings_defaults(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv('APP_VERSION', raising=False)

    settings = Settings(_env_file=None)

    assert settings.app_name == '{{ cookiecutter.project_name }}'
    assert settings.app_version == '0.0.0-dev'
    assert settings.docs_enabled is True


def test_settings_env_override(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv('APP_VERSION', 'abc1234')
    monkeypatch.setenv('APP_NAME', 'Outro Nome')
    monkeypatch.setenv('DOCS_ENABLED', 'false')

    settings = Settings(_env_file=None)

    assert settings.app_version == 'abc1234'
    assert settings.app_name == 'Outro Nome'
    assert settings.docs_enabled is False


def test_health_path() -> None:
    assert HEALTH_PATH == '{{ cookiecutter.health_path }}'
