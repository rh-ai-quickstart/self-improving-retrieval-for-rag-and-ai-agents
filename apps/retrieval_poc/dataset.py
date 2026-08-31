"""SciFact benchmark loading."""

from __future__ import annotations

from collections import defaultdict
from typing import TypeAlias

import numpy as np
from datasets import load_dataset


RetrievalBenchmark: TypeAlias = dict


def load_scifact(
    num_queries: int = 200,
    corpus_size: int = 2500,
    seed: int = 42,
) -> RetrievalBenchmark:
    """Load a deterministic development subset of SciFact.

    Every relevant document for the sampled queries is retained, then the
    corpus is filled to ``corpus_size`` with deterministic distractors.
    """
    if num_queries <= 0:
        raise ValueError("num_queries must be positive.")
    if corpus_size <= 0:
        raise ValueError("corpus_size must be positive.")

    corpus_ds = load_dataset(
        "BeIR/scifact",
        "corpus",
        split="corpus",
    )
    queries_ds = load_dataset(
        "BeIR/scifact",
        "queries",
        split="queries",
    )
    qrels_ds = load_dataset(
        "BeIR/scifact-qrels",
        split="test",
    )

    relevant_docs: dict[str, set[str]] = defaultdict(set)

    for row in qrels_ds:
        query_id = str(row["query-id"])
        corpus_id = str(row["corpus-id"])
        score = int(row["score"])

        if score > 0:
            relevant_docs[query_id].add(corpus_id)

    available_query_ids = sorted(relevant_docs)

    rng = np.random.default_rng(seed)
    if num_queries < len(available_query_ids):
        selected_query_ids = set(
            rng.choice(
                available_query_ids,
                size=num_queries,
                replace=False,
            ).tolist()
        )
    else:
        selected_query_ids = set(available_query_ids)

    full_corpus = {
        str(row["_id"]): _document_text(row)
        for row in corpus_ds
    }

    queries = {
        str(row["_id"]): str(row["text"])
        for row in queries_ds
        if str(row["_id"]) in selected_query_ids
    }

    filtered_relevant_docs = {
        query_id: sorted(relevant_docs[query_id])
        for query_id in queries
    }

    if not queries:
        raise RuntimeError("No labeled SciFact evaluation queries were loaded.")

    required_corpus_ids = {
        corpus_id
        for query_id in queries
        for corpus_id in filtered_relevant_docs[query_id]
    }
    missing_corpus_ids = required_corpus_ids - full_corpus.keys()
    if missing_corpus_ids:
        raise RuntimeError(
            "Relevant SciFact documents are missing from the corpus: "
            f"{sorted(missing_corpus_ids)}"
        )

    selected_corpus_ids = _select_corpus_ids(
        corpus_ids=list(full_corpus),
        required_corpus_ids=required_corpus_ids,
        corpus_size=corpus_size,
        rng=rng,
    )
    corpus = {
        corpus_id: text
        for corpus_id, text in full_corpus.items()
        if corpus_id in selected_corpus_ids
    }

    return {
        "corpus": corpus,
        "queries": queries,
        "relevant_docs": filtered_relevant_docs,
    }


def _select_corpus_ids(
    corpus_ids: list[str],
    required_corpus_ids: set[str],
    corpus_size: int,
    rng: np.random.Generator,
) -> set[str]:
    target_size = min(corpus_size, len(corpus_ids))
    if len(required_corpus_ids) > target_size:
        raise ValueError(
            f"corpus_size={corpus_size} cannot contain all "
            f"{len(required_corpus_ids)} relevant documents."
        )

    distractor_ids = sorted(set(corpus_ids) - required_corpus_ids)
    num_distractors = target_size - len(required_corpus_ids)
    selected_distractors = set(
        rng.choice(
            distractor_ids,
            size=num_distractors,
            replace=False,
        ).tolist()
    )
    return required_corpus_ids | selected_distractors


def _document_text(row: dict) -> str:
    title = str(row.get("title") or "").strip()
    text = str(row.get("text") or "").strip()

    if title:
        return f"{title}\n{text}"

    return text
