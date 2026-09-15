"""Shared fixtures for fast, offline apps unit tests."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

import faiss
import numpy as np
import pytest

from apps.retrieval_poc.retrieval.indexing import BUNDLE_FORMAT_VERSION, _deterministic_zip


@pytest.fixture
def mini_benchmark() -> dict[str, Any]:
    """Minimal benchmark dict for chunking, metrics, and bundle tests."""
    return {
        "dataset_id": "test/benchmark",
        "query_split": "DEV",
        "corpus": {"doc-a": "body a", "doc-b": "body b"},
        "documents": {
            "doc-a": {
                "id": "doc-a",
                "title": "Database recovery",
                "body": "one two three four five six",
            },
            "doc-b": {
                "id": "doc-b",
                "title": "Network checks",
                "body": "inspect connectivity and routes",
            },
        },
        "queries": {"q1": "database failure"},
        "relevant_docs": {"q1": ["doc-a"]},
    }


@pytest.fixture
def search_chunks() -> list[dict[str, Any]]:
    return [
        {
            "chunk_id": "db::0",
            "document_id": "db",
            "chunk_index": 0,
            "title": "Database recovery",
            "text": "Database recovery\n\nrestart the database",
            "snippet": "restart the database",
        },
        {
            "chunk_id": "network::0",
            "document_id": "network",
            "chunk_index": 0,
            "title": "Network checks",
            "text": "Network checks\n\ninspect connectivity",
            "snippet": "inspect connectivity",
        },
    ]


@pytest.fixture
def search_bundle_bytes(search_chunks: list[dict[str, Any]]) -> bytes:
    index = faiss.IndexFlatIP(2)
    index.add(np.asarray([[1.0, 0.0], [0.0, 1.0]], dtype=np.float32))
    index_bytes = faiss.serialize_index(index).tobytes()
    chunks_bytes = json.dumps(
        search_chunks, separators=(",", ":"), sort_keys=True
    ).encode()
    digest = hashlib.sha256(index_bytes + chunks_bytes).hexdigest()
    manifest = {
        "format_version": BUNDLE_FORMAT_VERSION,
        "bundle_digest": digest,
        "model_id": "fake/model",
        "query_prefix": "query: ",
        "document_prefix": "passage: ",
        "embedding_dimension": 2,
        "document_count": 2,
        "chunk_count": 2,
    }
    return _deterministic_zip(
        {
            "index.faiss": index_bytes,
            "chunks.json": chunks_bytes,
            "manifest.json": json.dumps(manifest).encode(),
        }
    )


@pytest.fixture
def search_bundle_path(tmp_path: Path, search_bundle_bytes: bytes) -> Path:
    bundle_path = tmp_path / "search-bundle.zip"
    bundle_path.write_bytes(search_bundle_bytes)
    return bundle_path


@pytest.fixture
def fake_sentence_transformer(monkeypatch) -> None:
    class FakeModel:
        def __init__(self, *_args, **_kwargs) -> None:
            pass

        def encode(self, texts, **_kwargs):
            vectors = []
            for text in texts:
                if "database" in text.lower():
                    vectors.append([1.0, 0.0])
                else:
                    vectors.append([0.0, 1.0])
            return np.asarray(vectors, dtype=np.float32)

    import apps.retrieval_poc.search_app.engine as engine_module

    monkeypatch.setattr(engine_module, "SentenceTransformer", FakeModel)


@pytest.fixture
def search_engine(
    search_bundle_path: Path,
    fake_sentence_transformer: None,
    search_bundle_bytes: bytes,
):
    from apps.retrieval_poc.search_app.engine import SearchEngine

    manifest = json.loads(
        __import__("zipfile")
        .ZipFile(__import__("io").BytesIO(search_bundle_bytes))
        .read("manifest.json")
    )
    return SearchEngine(
        search_bundle_path,
        expected_model_id="fake/model",
        expected_digest=manifest["bundle_digest"],
    )
