from fastapi import APIRouter

from config import HEALTH_PATH, settings
from models import HealthResponse{% if cookiecutter.health_path != '/' %}, RootResponse{% endif %}

router = APIRouter(tags=['meta'])


@router.get(HEALTH_PATH, response_model=HealthResponse, summary='Healthcheck')
def health() -> HealthResponse:
    return HealthResponse(status='ok', version=settings.app_version)
{%- if cookiecutter.health_path != '/' %}


@router.get('/', response_model=RootResponse, summary='Metadados da API')
def root() -> RootResponse:
    return RootResponse(
        name=settings.app_name,
        version=settings.app_version,
        health=HEALTH_PATH,
        docs='/docs' if settings.docs_enabled else None,
    )
{%- endif %}
