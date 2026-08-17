"""Small CPU embedding API used by the KServe custom predictor."""

from __future__ import annotations

import os
from contextlib import asynccontextmanager
from typing import Literal

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from sentence_transformers import SentenceTransformer


MODEL_ID = os.environ["MODEL_ID"]
QUERY_PREFIX = os.getenv("QUERY_PREFIX", "")
DOCUMENT_PREFIX = os.getenv("DOCUMENT_PREFIX", "")
MAX_INPUTS = int(os.getenv("MAX_INPUTS", "64"))

model: SentenceTransformer | None = None


class EmbeddingRequest(BaseModel):
    """Texts to embed and their role in the retrieval system."""

    inputs: str | list[str]
    input_type: Literal["query", "document", "raw"] = "raw"


@asynccontextmanager
async def lifespan(_: FastAPI):
    """Download and initialize the selected model before becoming ready."""
    global model
    model = SentenceTransformer(MODEL_ID, device="cpu")
    yield
    model = None


app = FastAPI(title="Retrieval embedding service", lifespan=lifespan)


@app.get("/health")
def health() -> dict[str, str]:
    """Expose readiness for KServe and human validation."""
    if model is None:
        raise HTTPException(status_code=503, detail="Model is not loaded")
    return {"status": "ready", "model_id": MODEL_ID}


@app.post("/embed")
def embed(request: EmbeddingRequest) -> dict[str, object]:
    """Return normalized embeddings from the selected retrieval model."""
    if model is None:
        raise HTTPException(status_code=503, detail="Model is not loaded")

    texts = (
        [request.inputs]
        if isinstance(request.inputs, str)
        else request.inputs
    )
    if not texts:
        raise HTTPException(status_code=422, detail="inputs cannot be empty")
    if len(texts) > MAX_INPUTS:
        raise HTTPException(
            status_code=422,
            detail=f"at most {MAX_INPUTS} inputs are allowed",
        )

    prefix = {
        "query": QUERY_PREFIX,
        "document": DOCUMENT_PREFIX,
        "raw": "",
    }[request.input_type]
    embeddings = model.encode(
        [prefix + text for text in texts],
        normalize_embeddings=True,
        convert_to_numpy=True,
        show_progress_bar=False,
    )
    return {
        "model_id": MODEL_ID,
        "input_type": request.input_type,
        "embeddings": embeddings.tolist(),
    }
