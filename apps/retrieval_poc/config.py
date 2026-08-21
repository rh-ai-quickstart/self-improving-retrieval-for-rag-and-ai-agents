"""Candidate embedding model configuration."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class ModelConfig:
    model_id: str
    query_prefix: str = ""
    document_prefix: str = ""
    batch_size: int = 64


MODELS: list[ModelConfig] = [
    ModelConfig(
        model_id="sentence-transformers/all-MiniLM-L6-v2",
    ),
    ModelConfig(
        model_id="BAAI/bge-small-en-v1.5",
        query_prefix="Represent this sentence for searching relevant passages: ",
    ),
    ModelConfig(
        model_id="intfloat/e5-small-v2",
        query_prefix="query: ",
        document_prefix="passage: ",
    ),
]
