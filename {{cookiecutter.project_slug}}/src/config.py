from pydantic_settings import BaseSettings, SettingsConfigDict

# Fixo no template: o mesmo caminho e usado no HEALTHCHECK, no compose e no Jenkinsfile.
HEALTH_PATH = '{{ cookiecutter.health_path }}'


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file='.env', env_file_encoding='utf-8', extra='ignore')

    app_name: str = '{{ cookiecutter.project_name }}'
    # Definida no build da imagem (--build-arg APP_VERSION=<sha>).
    app_version: str = '0.0.0-dev'
    docs_enabled: bool = True


settings = Settings()
