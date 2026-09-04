"""ZenML steps for evaluation, selection, indexing, and deployment."""

from __future__ import annotations

from typing import Any

import mlflow
from zenml import step
from zenml.metadata.metadata_types import Uri
from zenml.steps import get_step_context
from zenml.utils.metadata_utils import log_metadata

from apps.retrieval_poc.config import ModelConfig
from apps.retrieval_poc.infrastructure.bundle_store import publish_search_bundle
from apps.retrieval_poc.infrastructure.kserve import deploy_search_service
from apps.retrieval_poc.retrieval.dataset import RetrievalBenchmark, load_techqa
from apps.retrieval_poc.retrieval.evaluation import evaluate_model
from apps.retrieval_poc.retrieval.indexing import build_search_bundle


@step(enable_cache=True)
def prepare_dataset(
    num_queries: int = 160,
    corpus_size: int = 500,
    seed: int = 42,
    query_split: str = "DEV",
) -> RetrievalBenchmark:
    """Prepare the shared benchmark artifact once."""
    return load_techqa(
        num_queries=num_queries,
        corpus_size=corpus_size,
        seed=seed,
        query_split=query_split,
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
    chunk_size_words: int = 240,
    chunk_overlap_words: int = 40,
) -> dict[str, Any]:
    """Evaluate one candidate model and log its run to MLflow."""
    result = evaluate_model(
        model_config=model_config,
        benchmark=benchmark,
        top_k=top_k,
        chunk_size_words=chunk_size_words,
        chunk_overlap_words=chunk_overlap_words,
    )
    mlflow.log_params(
        {
            "dataset_id": benchmark["dataset_id"],
            "query_split": benchmark["query_split"],
            "model_id": model_config.model_id,
            "query_prefix": model_config.query_prefix,
            "document_prefix": model_config.document_prefix,
            "batch_size": model_config.batch_size,
            "corpus_size": result["corpus_size"],
            "chunk_count": result["chunk_count"],
            "chunk_size_words": result["chunk_size_words"],
            "chunk_overlap_words": result["chunk_overlap_words"],
            "num_queries": result["num_queries"],
            "top_k": top_k,
        }
    )
    mlflow.log_metrics(
        {
            key: float(result[key])
            for key in (
                "ndcg_at_10",
                "mrr_at_10",
                "recall_at_10",
                "recall_at_50",
                "precision_at_10",
                "map_at_10",
                "corpus_embedding_seconds",
                "query_embedding_seconds",
                "total_seconds",
                "queries_per_second",
            )
        }
    )
    mlflow.set_tags(
        {
            "task": "technical-support-document-retrieval",
            "dataset": benchmark["dataset_id"],
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
        raise KeyError(f"Metric {metric!r} missing for models: {missing_metric}")
    winner = max(results, key=lambda result: float(result[metric]))

    print("\nModel comparison")
    print("=" * 100)
    for result in sorted(
        results, key=lambda item: float(item[metric]), reverse=True
    ):
        print(
            f"{result['model_id']:<50} "
            f"NDCG@10={result['ndcg_at_10']:.4f}  "
            f"MRR@10={result['mrr_at_10']:.4f}  "
            f"R@10={result['recall_at_10']:.4f}  "
            f"R@50={result['recall_at_50']:.4f}  "
            f"P@10={result['precision_at_10']:.4f}  "
            f"MAP@10={result['map_at_10']:.4f}  "
            f"time={result['total_seconds']:.1f}s"
        )
    print("=" * 100)
    print(f"Winner: {winner['model_id']} ({metric}={float(winner[metric]):.4f})")
    log_metadata(
        metadata={
            "winning_model": str(winner["model_id"]),
            "selection_metric": metric,
            "winning_score": float(winner[metric]),
        }
    )
    return winner


@step(enable_cache=False, runtime="isolated")
def build_winner_search_index(
    benchmark: RetrievalBenchmark,
    winner: dict[str, Any],
    chunk_size_words: int = 240,
    chunk_overlap_words: int = 40,
) -> dict[str, Any]:
    """Build and persist the winner's versioned FAISS search bundle."""
    bundle_bytes, manifest = build_search_bundle(
        benchmark=benchmark,
        winner=winner,
        chunk_size_words=chunk_size_words,
        chunk_overlap_words=chunk_overlap_words,
    )
    bundle_uri = publish_search_bundle(
        bundle_bytes=bundle_bytes,
        digest=str(manifest["bundle_digest"]),
    )
    result = {
        **manifest,
        "bundle_uri": bundle_uri,
        "bundle_size_bytes": len(bundle_bytes),
    }
    metadata = {
        "bundle_uri": Uri(bundle_uri),
        "bundle_digest": str(manifest["bundle_digest"]),
        "document_count": int(manifest["document_count"]),
        "chunk_count": int(manifest["chunk_count"]),
        "embedding_dimension": int(manifest["embedding_dimension"]),
        "bundle_size_bytes": len(bundle_bytes),
    }
    log_metadata(metadata=metadata)
    log_metadata(metadata=metadata, infer_artifact=True)
    return result


@step(enable_cache=False)
def deploy_search_app(
    winner: dict[str, Any],
    bundle: dict[str, Any],
    deployment_name: str = "retrieval-embedding",
    timeout_seconds: int = 600,
    minio_endpoint: str = "http://minio:9000",
    minio_secret_name: str = "minio-root",
    minio_client_image: str = (
        "quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z"
    ),
) -> dict[str, Any]:
    """Deploy the indexed search app and publish links in ZenML."""
    result = deploy_search_service(
        winner=winner,
        bundle=bundle,
        deployment_name=deployment_name,
        timeout_seconds=timeout_seconds,
        minio_endpoint=minio_endpoint,
        minio_secret_name=minio_secret_name,
        minio_client_image=minio_client_image,
    )
    link_metadata = {
        "search_ui": Uri(str(result["ui_url"])),
        "search_api_docs": Uri(str(result["api_docs_url"])),
        "health_endpoint": Uri(str(result["health_url"])),
        "deployed_model": str(result["model_id"]),
        "bundle_digest": str(result["bundle_digest"]),
    }
    log_metadata(metadata=link_metadata)
    context = get_step_context()
    log_metadata(
        metadata=link_metadata,
        run_id_name_or_prefix=context.pipeline_run.id,
    )
    log_metadata(metadata=link_metadata, infer_artifact=True)
    return result
