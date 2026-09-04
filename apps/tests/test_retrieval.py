"""Fast unit tests for the shared retrieval and serving contracts."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import faiss
import numpy as np

from apps.retrieval_poc.retrieval.chunking import chunk_benchmark_documents
from apps.retrieval_poc.retrieval.evaluation import compute_metrics
from apps.retrieval_poc.retrieval.indexing import (
    BUNDLE_FORMAT_VERSION,
    _deterministic_zip,
    load_search_bundle,
)
from apps.retrieval_poc.search_app import engine as engine_module


def test_chunks_prepend_titles_and_overlap() -> None:
    benchmark = {
        "corpus": {"doc": "unused"},
        "documents": {
            "doc": {
                "id": "doc",
                "title": "Database recovery",
                "body": "one two three four five six",
            }
        },
    }
    chunks = chunk_benchmark_documents(
        benchmark, chunk_size_words=4, chunk_overlap_words=2
    )
    assert [chunk["snippet"] for chunk in chunks] == [
        "one two three four",
        "three four five six",
    ]
    assert chunks[0]["text"].startswith("Database recovery\n\n")


def test_document_metrics_use_ranked_documents() -> None:
    metrics = compute_metrics(
        ranked_doc_ids={"q": ["wrong", "relevant"]},
        relevant_docs={"q": ["relevant"]},
    )
    assert metrics["mrr_at_10"] == 0.5
    assert metrics["recall_at_10"] == 1.0
    assert metrics["precision_at_10"] == 0.1
    assert metrics["map_at_10"] == 0.5


def test_search_engine_loads_bundle_and_collapses_documents(
    tmp_path: Path,
    monkeypatch,
) -> None:
    chunks = [
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
    index = faiss.IndexFlatIP(2)
    index.add(np.asarray([[1.0, 0.0], [0.0, 1.0]], dtype=np.float32))
    index_bytes = faiss.serialize_index(index).tobytes()
    chunks_bytes = json.dumps(
        chunks, separators=(",", ":"), sort_keys=True
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
    bundle = _deterministic_zip(
        {
            "index.faiss": index_bytes,
            "chunks.json": chunks_bytes,
            "manifest.json": json.dumps(manifest).encode(),
        }
    )
    bundle_path = tmp_path / "bundle.zip"
    bundle_path.write_bytes(bundle)

    class FakeModel:
        def __init__(self, *_args, **_kwargs) -> None:
            pass

        def encode(self, texts, **_kwargs):
            assert texts == ["query: database failure"]
            return np.asarray([[1.0, 0.0]], dtype=np.float32)

    monkeypatch.setattr(engine_module, "SentenceTransformer", FakeModel)
    search_engine = engine_module.SearchEngine(
        bundle_path,
        expected_model_id="fake/model",
        expected_digest=digest,
    )
    response = search_engine.search("database failure", top_k=2)
    assert [result["document_id"] for result in response["results"]] == [
        "db",
        "network",
    ]
    loaded_index, loaded_chunks, loaded_manifest = load_search_bundle(bundle)
    assert loaded_index.ntotal == 2
    assert loaded_chunks == chunks
    assert loaded_manifest["bundle_digest"] == digest

