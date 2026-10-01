import pytest
from fastapi.testclient import TestClient

import routes.meta
from config import HEALTH_PATH, Settings, settings
from main import create_app


def test_health(client: TestClient) -> None:
    response = client.get(HEALTH_PATH)

    assert response.status_code == 200
    assert response.json() == {'status': 'ok', 'version': settings.app_version}


def test_health_reports_app_version(monkeypatch: pytest.MonkeyPatch, client: TestClient) -> None:
    monkeypatch.setattr(routes.meta, 'settings', Settings(_env_file=None, app_version='abc1234'))

    response = client.get(HEALTH_PATH)

    assert response.json()['version'] == 'abc1234'
{%- if cookiecutter.health_path != '/' %}


def test_root(client: TestClient) -> None:
    response = client.get('/')

    assert response.status_code == 200
    assert response.json() == {
        'name': settings.app_name,
        'version': settings.app_version,
        'health': HEALTH_PATH,
        'docs': '/docs',
    }


def test_root_without_docs(monkeypatch: pytest.MonkeyPatch, client: TestClient) -> None:
    monkeypatch.setattr(routes.meta, 'settings', Settings(_env_file=None, docs_enabled=False))

    assert client.get('/').json()['docs'] is None
{%- endif %}


def test_docs_enabled(client: TestClient) -> None:
    assert client.get('/docs').status_code == 200
    assert client.get('/openapi.json').status_code == 200


def test_docs_disabled() -> None:
    app = create_app(Settings(_env_file=None, docs_enabled=False))
    client = TestClient(app)

    assert client.get('/docs').status_code == 404
    assert client.get('/openapi.json').status_code == 404
