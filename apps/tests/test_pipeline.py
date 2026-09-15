"""Unit tests for model-selection logic."""

from __future__ import annotations

import pytest

from apps.retrieval_poc.pipeline.selection import choose_best_model


def _result(model_id: str, ndcg: float) -> dict[str, float | str]:
    return {
        "model_id": model_id,
        "ndcg_at_10": ndcg,
        "mrr_at_10": 0.1,
        "recall_at_10": 0.1,
        "recall_at_50": 0.1,
        "precision_at_10": 0.1,
        "map_at_10": 0.1,
        "total_seconds": 1.0,
    }


def test_choose_best_model_uses_requested_metric() -> None:
    results = [_result("slow-model", 0.4), _result("fast-model", 0.9)]
    winner = choose_best_model(results, metric="ndcg_at_10")
    assert winner["model_id"] == "fast-model"


def test_choose_best_model_rejects_empty_results() -> None:
    with pytest.raises(ValueError, match="No model evaluation results"):
        choose_best_model([])


def test_choose_best_model_requires_metric() -> None:
    with pytest.raises(KeyError, match="missing for models"):
        choose_best_model([{"model_id": "broken-model"}], metric="ndcg_at_10")
