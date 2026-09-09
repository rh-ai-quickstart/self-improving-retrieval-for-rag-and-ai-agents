"""Chunk-aware dense-retrieval evaluation and ranking metrics."""

from __future__ import annotations

import math
import time
from collections.abc import Iterable
from typing import Any

import numpy as np
from sentence_transformers import SentenceTransformer

from apps.retrieval_poc.config import ModelConfig
from apps.retrieval_poc.retrieval.chunking import (
    chunk_benchmark_documents,
    collapse_chunk_ranking,
)
from apps.retrieval_poc.retrieval.dataset import RetrievalBenchmark


def evaluate_model(
    model_config: ModelConfig,
    benchmark: RetrievalBenchmark,
    top_k: int = 50,
    chunk_size_words: int = 240,
    chunk_overlap_words: int = 40,
) -> dict[str, Any]:
    """Embed shared chunks and rank documents by their best chunk score."""
    if top_k <= 0:
        raise ValueError("top_k must be positive.")

    chunks = chunk_benchmark_documents(
        benchmark,
        chunk_size_words=chunk_size_words,
        chunk_overlap_words=chunk_overlap_words,
    )
    model = SentenceTransformer(model_config.model_id)
    corpus_texts = [
        model_config.document_prefix + chunk["text"] for chunk in chunks
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

    scores = query_embeddings @ corpus_embeddings.T
    effective_k = min(top_k, len(benchmark["corpus"]))
    ranked_doc_ids: dict[str, list[str]] = {}
    for query_index, query_id in enumerate(query_ids):
        ranked_chunks = np.argsort(-scores[query_index]).tolist()
        ranked_doc_ids[query_id] = collapse_chunk_ranking(
            ranked_chunks, chunks, effective_k
        )

    metrics = compute_metrics(
        ranked_doc_ids=ranked_doc_ids,
        relevant_docs=benchmark["relevant_docs"],
    )
    total_seconds = time.perf_counter() - total_started
    return {
        "model_id": model_config.model_id,
        "query_prefix": model_config.query_prefix,
        "document_prefix": model_config.document_prefix,
        "batch_size": model_config.batch_size,
        "embedding_dimension": int(corpus_embeddings.shape[1]),
        "num_queries": len(query_ids),
        "corpus_size": len(benchmark["corpus"]),
        "chunk_count": len(chunks),
        "chunk_size_words": chunk_size_words,
        "chunk_overlap_words": chunk_overlap_words,
        **metrics,
        "corpus_embedding_seconds": corpus_seconds,
        "query_embedding_seconds": query_seconds,
        "total_seconds": total_seconds,
        "queries_per_second": (
            len(query_ids) / query_seconds if query_seconds > 0 else 0.0
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
    precisions_10: list[float] = []
    average_precisions_10: list[float] = []
    for query_id, ranking in ranked_doc_ids.items():
        relevant = set(relevant_docs[query_id])
        ndcgs.append(_ndcg(ranking[:10], relevant))
        mrrs.append(_reciprocal_rank(ranking[:10], relevant))
        recalls_10.append(_recall(ranking[:10], relevant))
        recalls_50.append(_recall(ranking[:50], relevant))
        precisions_10.append(_precision(ranking[:10], relevant, k=10))
        average_precisions_10.append(
            _average_precision(ranking[:10], relevant, k=10)
        )
    return {
        "ndcg_at_10": float(np.mean(ndcgs)),
        "mrr_at_10": float(np.mean(mrrs)),
        "recall_at_10": float(np.mean(recalls_10)),
        "recall_at_50": float(np.mean(recalls_50)),
        "precision_at_10": float(np.mean(precisions_10)),
        "map_at_10": float(np.mean(average_precisions_10)),
    }


def _recall(ranking: Iterable[str], relevant: set[str]) -> float:
    return len(set(ranking) & relevant) / len(relevant) if relevant else 0.0


def _reciprocal_rank(ranking: Iterable[str], relevant: set[str]) -> float:
    for rank, doc_id in enumerate(ranking, start=1):
        if doc_id in relevant:
            return 1.0 / rank
    return 0.0


def _precision(ranking: Iterable[str], relevant: set[str], k: int) -> float:
    if k <= 0:
        raise ValueError("k must be positive.")
    return len(set(ranking) & relevant) / k


def _average_precision(
    ranking: Iterable[str], relevant: set[str], k: int
) -> float:
    if not relevant:
        return 0.0
    if k <= 0:
        raise ValueError("k must be positive.")
    hits = 0
    precision_sum = 0.0
    for rank, document_id in enumerate(ranking, start=1):
        if document_id in relevant:
            hits += 1
            precision_sum += hits / rank
    return precision_sum / min(len(relevant), k)


def _ndcg(ranking: list[str], relevant: set[str]) -> float:
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

