"""HTTP request and response contracts for semantic search."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class SearchRequest(BaseModel):
    query: str = Field(min_length=1, max_length=2_000)
    top_k: int = Field(default=5, ge=1, le=20)


class SearchResult(BaseModel):
    rank: int
    document_id: str
    chunk_id: str
    chunk_index: int
    title: str
    snippet: str
    score: float


class SearchResponse(BaseModel):
    query: str
    model_id: str
    bundle_digest: str
    elapsed_ms: float
    results: list[SearchResult]


class EmbeddingRequest(BaseModel):
    inputs: str | list[str]
    input_type: Literal["query", "document", "raw"] = "raw"

