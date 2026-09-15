"""Unit tests for retrieval ranking metrics."""

from __future__ import annotations

import pytest

from apps.retrieval_poc.retrieval.evaluation import compute_metrics


def test_document_metrics_use_ranked_documents() -> None:
    metrics = compute_metrics(
        ranked_doc_ids={"q": ["wrong", "relevant"]},
        relevant_docs={"q": ["relevant"]},
    )
    assert metrics["mrr_at_10"] == 0.5
    assert metrics["recall_at_10"] == 1.0
    assert metrics["precision_at_10"] == 0.1
    assert metrics["map_at_10"] == 0.5


def test_perfect_ranking_scores_one() -> None:
    metrics = compute_metrics(
        ranked_doc_ids={"q": ["relevant", "other"]},
        relevant_docs={"q": ["relevant"]},
    )
    assert metrics["ndcg_at_10"] == 1.0
    assert metrics["mrr_at_10"] == 1.0
    assert metrics["recall_at_10"] == 1.0


def test_missing_relevant_documents_score_zero() -> None:
    metrics = compute_metrics(
        ranked_doc_ids={"q": ["a", "b", "c"]},
        relevant_docs={"q": ["missing"]},
    )
    assert metrics["ndcg_at_10"] == 0.0
    assert metrics["mrr_at_10"] == 0.0
    assert metrics["recall_at_10"] == 0.0


def test_metrics_average_across_queries() -> None:
    metrics = compute_metrics(
        ranked_doc_ids={
            "q1": ["hit"],
            "q2": ["miss", "hit"],
        },
        relevant_docs={"q1": ["hit"], "q2": ["hit"]},
    )
    assert metrics["mrr_at_10"] == pytest.approx(0.75)
    assert metrics["recall_at_10"] == 1.0
