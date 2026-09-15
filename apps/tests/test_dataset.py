"""Unit tests for TechQA benchmark helpers."""

from __future__ import annotations

import numpy as np
import pytest

from apps.retrieval_poc.retrieval import dataset as dataset_module
from apps.retrieval_poc.retrieval.dataset import (
    _document_metadata,
    _select_corpus_ids,
    load_techqa,
)


def test_document_metadata_parses_title_block() -> None:
    text = "Title: Database recovery\n\nText:\nRestart the database service."
    metadata = _document_metadata("doc.txt", text)
    assert metadata["title"] == "Database recovery"
    assert metadata["body"] == "Restart the database service."


def test_document_metadata_falls_back_to_document_id() -> None:
    metadata = _document_metadata("fallback.txt", "plain body text")
    assert metadata["title"] == "fallback.txt"
    assert metadata["body"] == "plain body text"


def test_select_corpus_ids_includes_required_documents() -> None:
    rng = np.random.default_rng(42)
    selected = _select_corpus_ids(
        corpus_ids=["a", "b", "c", "d"],
        required_corpus_ids={"a", "b"},
        corpus_size=3,
        rng=rng,
    )
    assert selected == {"a", "b"} | set(selected) - {"a", "b"}
    assert len(selected) == 3
    assert {"a", "b"}.issubset(selected)


def test_select_corpus_ids_rejects_too_small_corpus() -> None:
    rng = np.random.default_rng(42)
    with pytest.raises(ValueError, match="cannot contain all"):
        _select_corpus_ids(
            corpus_ids=["a", "b", "c"],
            required_corpus_ids={"a", "b", "c"},
            corpus_size=2,
            rng=rng,
        )


def test_load_techqa_validation_errors() -> None:
    with pytest.raises(ValueError, match="num_queries must be positive"):
        load_techqa(num_queries=0)
    with pytest.raises(ValueError, match="corpus_size must be positive"):
        load_techqa(corpus_size=0)
    with pytest.raises(ValueError, match="query_split must be one of"):
        load_techqa(query_split="INVALID")


def test_load_techqa_is_deterministic_for_same_seed(monkeypatch) -> None:
    rows = [
        {
            "id": "DEV_001",
            "question": "How do I restart the database?",
            "is_impossible": False,
            "contexts": [
                {"filename": "db.txt", "text": "Title: DB\n\nText:\nRestart steps."},
            ],
        },
        {
            "id": "DEV_002",
            "question": "How do I check network routes?",
            "is_impossible": False,
            "contexts": [
                {"filename": "net.txt", "text": "Title: Net\n\nText:\nRoute checks."},
            ],
        },
    ]

    monkeypatch.setattr(
        dataset_module,
        "load_dataset",
        lambda *_args, **_kwargs: rows,
    )
    first = load_techqa(num_queries=2, corpus_size=2, seed=7, query_split="DEV")
    second = load_techqa(num_queries=2, corpus_size=2, seed=7, query_split="DEV")
    assert first == second
    assert set(first["corpus"]) == {"db.txt", "net.txt"}
    assert first["relevant_docs"]["DEV_001"] == ["db.txt"]
