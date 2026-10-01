from pydantic import BaseModel


class HealthResponse(BaseModel):
    status: str
    version: str


class RootResponse(BaseModel):
    name: str
    version: str
    health: str
    docs: str | None
