"""Dense-retrieval evaluation and ranking metrics."""

from __future__ import annotations

import math
import time
from collections.abc import Iterable
from typing import Any

import numpy as np
from sentence_transformers import SentenceTransformer

from apps.retrieval_poc.config import ModelConfig
from apps.retrieval_poc.dataset import RetrievalBenchmark


def evaluate_model(
    model_config: ModelConfig,
    benchmark: RetrievalBenchmark,
    top_k: int = 50,
) -> dict[str, Any]:
    """Embed the corpus and queries, perform exact retrieval, and score it."""
    if top_k <= 0:
        raise ValueError("top_k must be positive.")

    model = SentenceTransformer(model_config.model_id)

    corpus_ids = list(benchmark["corpus"])
    corpus_texts = [
        model_config.document_prefix + benchmark["corpus"][doc_id]
        for doc_id in corpus_ids
    ]

    query_ids = list(benchmark["queries"])
    query_texts = [
        model_config.query_prefix + benchmark["queries"][query_id]
        for query_id in query_ids
    ]

    total_started = time.perf_counter()

    corpus_started = time.perf_counter()
    corpus_embeddings = model.encode(
        corpus_texts,
        batch_size=model_config.batch_size,
        normalize_embeddings=True,
        convert_to_numpy=True,
        show_progress_bar=True,
    )
    corpus_seconds = time.perf_counter() - corpus_started

    query_started = time.perf_counter()
    query_embeddings = model.encode(
        query_texts,
        batch_size=model_config.batch_size,
        normalize_embeddings=True,
        convert_to_numpy=True,
        show_progress_bar=False,
    )
    query_seconds = time.perf_counter() - query_started

    # Since both embedding matrices are normalized, dot product equals cosine.
    scores = query_embeddings @ corpus_embeddings.T

    effective_k = min(top_k, len(corpus_ids))

    candidate_indices = np.argpartition(
        -scores,
        kth=effective_k - 1,
        axis=1,
    )[:, :effective_k]

    ranked_doc_ids: dict[str, list[str]] = {}

    for query_index, query_id in enumerate(query_ids):
        indices = candidate_indices[query_index]
        sorted_indices = indices[
            np.argsort(-scores[query_index, indices])
        ]

        ranked_doc_ids[query_id] = [
            corpus_ids[int(index)]
            for index in sorted_indices
        ]

    metrics = compute_metrics(
        ranked_doc_ids=ranked_doc_ids,
        relevant_docs=benchmark["relevant_docs"],
    )

    total_seconds = time.perf_counter() - total_started

    return {
        "model_id": model_config.model_id,
        "query_prefix": model_config.query_prefix,
        "document_prefix": model_config.document_prefix,
        "embedding_dimension": int(corpus_embeddings.shape[1]),
        "num_queries": len(query_ids),
        "corpus_size": len(corpus_ids),
        "ndcg_at_10": metrics["ndcg_at_10"],
        "mrr_at_10": metrics["mrr_at_10"],
        "recall_at_10": metrics["recall_at_10"],
        "recall_at_50": metrics["recall_at_50"],
        "corpus_embedding_seconds": corpus_seconds,
        "query_embedding_seconds": query_seconds,
        "total_seconds": total_seconds,
        "queries_per_second": (
            len(query_ids) / query_seconds
            if query_seconds > 0
            else 0.0
        ),
    }


def compute_metrics(
    ranked_doc_ids: dict[str, list[str]],
    relevant_docs: dict[str, list[str]],
) -> dict[str, float]:
    ndcgs: list[float] = []
    mrrs: list[float] = []
    recalls_10: list[float] = []
    recalls_50: list[float] = []

    for query_id, ranking in ranked_doc_ids.items():
        relevant = set(relevant_docs[query_id])

        ndcgs.append(_ndcg(ranking[:10], relevant))
        mrrs.append(_reciprocal_rank(ranking[:10], relevant))
        recalls_10.append(_recall(ranking[:10], relevant))
        recalls_50.append(_recall(ranking[:50], relevant))

    return {
        "ndcg_at_10": float(np.mean(ndcgs)),
        "mrr_at_10": float(np.mean(mrrs)),
        "recall_at_10": float(np.mean(recalls_10)),
        "recall_at_50": float(np.mean(recalls_50)),
    }


def _recall(
    ranking: Iterable[str],
    relevant: set[str],
) -> float:
    if not relevant:
        return 0.0

    return len(set(ranking) & relevant) / len(relevant)


def _reciprocal_rank(
    ranking: Iterable[str],
    relevant: set[str],
) -> float:
    for rank, doc_id in enumerate(ranking, start=1):
        if doc_id in relevant:
            return 1.0 / rank

    return 0.0


def _ndcg(
    ranking: list[str],
    relevant: set[str],
) -> float:
    if not relevant:
        return 0.0

    dcg = sum(
        1.0 / math.log2(rank + 1)
        for rank, doc_id in enumerate(ranking, start=1)
        if doc_id in relevant
    )

    ideal_hits = min(len(relevant), len(ranking))

    idcg = sum(
        1.0 / math.log2(rank + 1)
        for rank in range(1, ideal_hits + 1)
    )

    return dcg / idcg if idcg else 0.0
