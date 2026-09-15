"""Unit tests for the in-memory search engine."""

from __future__ import annotations

import pytest

from apps.retrieval_poc.search_app.engine import SearchEngine, _shorten


def test_search_engine_loads_bundle_and_collapses_documents(
    search_engine,
    search_bundle_bytes,
    search_chunks,
) -> None:
    from apps.retrieval_poc.retrieval.indexing import load_search_bundle

    response = search_engine.search("database failure", top_k=2)
    assert [result["document_id"] for result in response["results"]] == [
        "db",
        "network",
    ]
    loaded_index, loaded_chunks, loaded_manifest = load_search_bundle(
        search_bundle_bytes
    )
    assert loaded_index.ntotal == 2
    assert loaded_chunks == search_chunks
    assert loaded_manifest["bundle_digest"]


def test_search_rejects_empty_query(search_engine) -> None:
    with pytest.raises(ValueError, match="query cannot be empty"):
        search_engine.search("   ", top_k=1)


def test_search_engine_validates_expected_model_id(search_bundle_path) -> None:
    with pytest.raises(ValueError, match="does not match bundle"):
        SearchEngine(search_bundle_path, expected_model_id="other/model")


def test_embed_applies_prefixes(search_engine, monkeypatch) -> None:
    captured: list[str] = []

    def fake_encode(self, texts, **_kwargs):
        captured.extend(texts)
        import numpy as np

        return np.asarray([[1.0, 0.0]] * len(texts), dtype=np.float32)

    monkeypatch.setattr(search_engine, "_encode", fake_encode.__get__(search_engine))
    search_engine.embed(["failure"], input_type="query")
    search_engine.embed(["body"], input_type="document")
    search_engine.embed(["plain"], input_type="raw")
    assert captured == ["query: failure", "passage: body", "plain"]


def test_shorten_truncates_long_snippets() -> None:
    text = "word " * 200
    shortened = _shorten(text, max_characters=50)
    assert len(shortened) <= 51
    assert shortened.endswith("…")
