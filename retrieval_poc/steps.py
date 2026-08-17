"""ZenML steps for evaluating and selecting an embedding model."""

from __future__ import annotations

from typing import Any

import mlflow
from zenml import step

from retrieval_poc.config import ModelConfig
from retrieval_poc.dataset import RetrievalBenchmark, load_scifact
from retrieval_poc.evaluation import evaluate_model


@step(enable_cache=True)
def prepare_dataset(
    num_queries: int = 200,
    corpus_size: int = 2500,
    seed: int = 42,
) -> RetrievalBenchmark:
    """Prepare the shared benchmark artifact once."""
    return load_scifact(
        num_queries=num_queries,
        corpus_size=corpus_size,
        seed=seed,
    )


@step(
    experiment_tracker=True,
    runtime="isolated",
    enable_cache=False,
    settings={"experiment_tracker.mlflow": {"nested": True}},
)
def evaluate_embedding_model(
    benchmark: RetrievalBenchmark,
    model_config: ModelConfig,
    top_k: int = 50,
) -> dict[str, Any]:
    """Evaluate one candidate model and log its run to MLflow."""
    result = evaluate_model(
        model_config=model_config,
        benchmark=benchmark,
        top_k=top_k,
    )

    mlflow.log_params(
        {
            "model_id": model_config.model_id,
            "query_prefix": model_config.query_prefix,
            "document_prefix": model_config.document_prefix,
            "batch_size": model_config.batch_size,
            "corpus_size": result["corpus_size"],
            "num_queries": result["num_queries"],
            "top_k": top_k,
        }
    )

    mlflow.log_metrics(
        {
            "ndcg_at_10": float(result["ndcg_at_10"]),
            "mrr_at_10": float(result["mrr_at_10"]),
            "recall_at_10": float(result["recall_at_10"]),
            "recall_at_50": float(result["recall_at_50"]),
            "corpus_embedding_seconds": float(
                result["corpus_embedding_seconds"]
            ),
            "query_embedding_seconds": float(
                result["query_embedding_seconds"]
            ),
            "total_seconds": float(result["total_seconds"]),
            "queries_per_second": float(result["queries_per_second"]),
        }
    )

    mlflow.set_tags(
        {
            "task": "snippet-retrieval",
            "dataset": "BEIR/SciFact",
            "model_provider": model_config.model_id.split("/")[0],
        }
    )

    return result


@step
def select_best_model(
    results: list[dict[str, Any]],
    metric: str = "ndcg_at_10",
) -> dict[str, Any]:
    """Select and return the best model according to the requested metric."""
    if not results:
        raise ValueError("No model evaluation results were provided.")

    missing_metric = [
        result.get("model_id", "<unknown>")
        for result in results
        if metric not in result
    ]
    if missing_metric:
        raise KeyError(
            f"Metric {metric!r} missing for models: {missing_metric}"
        )

    winner = max(
        results,
        key=lambda result: float(result[metric]),
    )

    print("\nModel comparison")
    print("=" * 100)

    for result in sorted(
        results,
        key=lambda item: float(item[metric]),
        reverse=True,
    ):
        print(
            f"{result['model_id']:<50} "
            f"NDCG@10={result['ndcg_at_10']:.4f}  "
            f"MRR@10={result['mrr_at_10']:.4f}  "
            f"R@10={result['recall_at_10']:.4f}  "
            f"R@50={result['recall_at_50']:.4f}  "
            f"time={result['total_seconds']:.1f}s"
        )

    print("=" * 100)
    print(
        f"Winner: {winner['model_id']} "
        f"({metric}={float(winner[metric]):.4f})"
    )

    return winner
