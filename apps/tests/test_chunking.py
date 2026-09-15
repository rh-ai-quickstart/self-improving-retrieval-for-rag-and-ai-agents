"""Unit tests for deterministic document chunking."""

from __future__ import annotations

import pytest

from apps.retrieval_poc.retrieval.chunking import (
    chunk_benchmark_documents,
    collapse_chunk_ranking,
)


def test_chunks_prepend_titles_and_overlap(mini_benchmark) -> None:
    chunks = chunk_benchmark_documents(
        mini_benchmark, chunk_size_words=4, chunk_overlap_words=2
    )
    doc_a_chunks = [chunk for chunk in chunks if chunk["document_id"] == "doc-a"]
    assert [chunk["snippet"] for chunk in doc_a_chunks] == [
        "one two three four",
        "three four five six",
    ]
    assert doc_a_chunks[0]["text"].startswith("Database recovery\n\n")


def test_empty_body_falls_back_to_title(mini_benchmark) -> None:
    mini_benchmark["documents"]["doc-a"]["body"] = "   "
    chunks = chunk_benchmark_documents(mini_benchmark, chunk_size_words=4, chunk_overlap_words=0)
    assert chunks[0]["snippet"] == "Database recovery"


def test_chunk_validation_rejects_invalid_sizes(mini_benchmark) -> None:
    with pytest.raises(ValueError, match="chunk_size_words must be positive"):
        chunk_benchmark_documents(mini_benchmark, chunk_size_words=0)
    with pytest.raises(ValueError, match="chunk_overlap_words cannot be negative"):
        chunk_benchmark_documents(mini_benchmark, chunk_overlap_words=-1)
    with pytest.raises(ValueError, match="chunk_overlap_words must be smaller"):
        chunk_benchmark_documents(
            mini_benchmark, chunk_size_words=4, chunk_overlap_words=4
        )


def test_collapse_chunk_ranking_deduplicates_documents() -> None:
    chunks = [
        {"document_id": "a", "chunk_id": "a::0", "chunk_index": 0, "title": "", "text": "", "snippet": ""},
        {"document_id": "a", "chunk_id": "a::1", "chunk_index": 1, "title": "", "text": "", "snippet": ""},
        {"document_id": "b", "chunk_id": "b::0", "chunk_index": 0, "title": "", "text": "", "snippet": ""},
    ]
    assert collapse_chunk_ranking([0, 1, 2], chunks, limit=2) == ["a", "b"]
    assert collapse_chunk_ranking([1, 0], chunks, limit=1) == ["a"]


def test_collapse_chunk_ranking_requires_positive_limit() -> None:
    with pytest.raises(ValueError, match="limit must be positive"):
        collapse_chunk_ranking([], [], limit=0)
