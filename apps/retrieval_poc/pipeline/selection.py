"""Pure model-selection logic used by the ZenML pipeline."""

from __future__ import annotations

from typing import Any


def choose_best_model(
    results: list[dict[str, Any]],
    metric: str = "ndcg_at_10",
) -> dict[str, Any]:
    """Return the best evaluation result for the requested metric."""
    if not results:
        raise ValueError("No model evaluation results were provided.")
    missing_metric = [
        result.get("model_id", "<unknown>")
        for result in results
        if metric not in result
    ]
    if missing_metric:
        raise KeyError(f"Metric {metric!r} missing for models: {missing_metric}")
    return max(results, key=lambda result: float(result[metric]))
