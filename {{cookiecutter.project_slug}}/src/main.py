import uvicorn
from fastapi import FastAPI

from config import Settings, settings
from routes.meta import router


def create_app(config: Settings = settings) -> FastAPI:
    docs_url = '/docs' if config.docs_enabled else None
    app = FastAPI(
        title=config.app_name,
        version=config.app_version,
        docs_url=docs_url,
        redoc_url=None,
        openapi_url='/openapi.json' if config.docs_enabled else None,
    )
    app.include_router(router)
    return app


app = create_app()

if __name__ == '__main__':
    uvicorn.run(app, host='0.0.0.0', port={{ cookiecutter.app_port }})
