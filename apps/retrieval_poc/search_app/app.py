"""FastAPI application exposing TechQA search, embeddings, and a small UI."""

from __future__ import annotations

import os
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from apps.retrieval_poc.search_app.engine import SearchEngine
from apps.retrieval_poc.search_app.schemas import (
    EmbeddingRequest,
    SearchRequest,
    SearchResponse,
)


STATIC_DIRECTORY = Path(__file__).with_name("static")
MAX_INPUTS = int(os.getenv("MAX_INPUTS", "64"))
engine: SearchEngine | None = None


@asynccontextmanager
async def lifespan(_: FastAPI):
    global engine
    engine = SearchEngine(
        bundle_path=Path(
            os.getenv(
                "SEARCH_BUNDLE_PATH",
                "/opt/search-bundle/search-bundle.zip",
            )
        ),
        expected_model_id=os.getenv("MODEL_ID", ""),
        expected_digest=os.getenv("SEARCH_BUNDLE_DIGEST", ""),
    )
    yield
    engine = None


app = FastAPI(
    title="TechQA semantic search",
    description="Search enterprise technical-support documentation.",
    lifespan=lifespan,
)
app.mount("/static", StaticFiles(directory=STATIC_DIRECTORY), name="static")


@app.get("/", include_in_schema=False)
def index() -> FileResponse:
    return FileResponse(STATIC_DIRECTORY / "index.html")


@app.get("/health")
def health() -> dict[str, object]:
    active = _engine()
    return {
        "status": "ready",
        "model_id": active.model_id,
        "bundle_digest": active.manifest["bundle_digest"],
        "document_count": active.manifest["document_count"],
        "chunk_count": active.manifest["chunk_count"],
    }


@app.post("/search", response_model=SearchResponse)
def search(request: SearchRequest) -> dict[str, object]:
    try:
        return _engine().search(request.query, request.top_k)
    except ValueError as error:
        raise HTTPException(status_code=422, detail=str(error)) from error


@app.post("/embed")
def embed(request: EmbeddingRequest) -> dict[str, object]:
    texts = [request.inputs] if isinstance(request.inputs, str) else request.inputs
    if not texts:
        raise HTTPException(status_code=422, detail="inputs cannot be empty")
    if len(texts) > MAX_INPUTS:
        raise HTTPException(
            status_code=422,
            detail=f"at most {MAX_INPUTS} inputs are allowed",
        )
    embeddings = _engine().embed(texts, request.input_type)
    return {
        "model_id": _engine().model_id,
        "input_type": request.input_type,
        "embeddings": embeddings.tolist(),
    }


def _engine() -> SearchEngine:
    if engine is None:
        raise HTTPException(status_code=503, detail="Search engine is not loaded")
    return engine

