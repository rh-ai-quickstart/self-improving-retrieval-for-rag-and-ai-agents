"""TechQA technical-support retrieval benchmark loading."""

from __future__ import annotations

from typing import Any, TypeAlias

import numpy as np
from datasets import load_dataset


TECHQA_DATASET_ID = "nvidia/TechQA-RAG-Eval"
TECHQA_DEFAULT_QUERY_SPLIT = "DEV"

RetrievalBenchmark: TypeAlias = dict[str, Any]


def load_techqa(
    num_queries: int = 160,
    corpus_size: int = 500,
    seed: int = 42,
    query_split: str = TECHQA_DEFAULT_QUERY_SPLIT,
) -> RetrievalBenchmark:
    """Load a deterministic TechQA retrieval benchmark.

    Answerable rows contain one relevant IBM Technote. Unanswerable rows are
    excluded because they do not define relevance judgments for IR metrics.
    """
    if num_queries <= 0:
        raise ValueError("num_queries must be positive.")
    if corpus_size <= 0:
        raise ValueError("corpus_size must be positive.")

    normalized_query_split = query_split.strip().upper()
    if normalized_query_split not in {"TRAIN", "DEV", "ALL"}:
        raise ValueError("query_split must be one of: TRAIN, DEV, ALL.")

    dataset = load_dataset(TECHQA_DATASET_ID, split="train")
    answerable_rows = [
        row
        for row in dataset
        if not bool(row["is_impossible"]) and bool(row["contexts"])
    ]

    full_corpus: dict[str, str] = {}
    document_metadata: dict[str, dict[str, str]] = {}
    for row in answerable_rows:
        for context in row["contexts"]:
            document_id = str(context["filename"])
            document_text = str(context["text"]).strip()
            existing_text = full_corpus.setdefault(document_id, document_text)
            if existing_text != document_text:
                raise RuntimeError(
                    f"TechQA document {document_id!r} has conflicting content."
                )
            document_metadata[document_id] = _document_metadata(
                document_id=document_id,
                document_text=document_text,
            )

    eligible_rows = [
        row
        for row in answerable_rows
        if normalized_query_split == "ALL"
        or str(row["id"]).upper().startswith(f"{normalized_query_split}_")
    ]
    eligible_rows.sort(key=lambda row: str(row["id"]))
    if not eligible_rows:
        raise RuntimeError(
            f"No answerable TechQA {normalized_query_split} queries were loaded."
        )

    rng = np.random.default_rng(seed)
    if num_queries < len(eligible_rows):
        selected_indices = sorted(
            int(index)
            for index in rng.choice(
                len(eligible_rows), size=num_queries, replace=False
            )
        )
        selected_rows = [eligible_rows[index] for index in selected_indices]
    else:
        selected_rows = eligible_rows

    queries = {
        str(row["id"]): str(row["question"]).strip()
        for row in selected_rows
    }
    relevant_docs = {
        str(row["id"]): sorted(
            {str(context["filename"]) for context in row["contexts"]}
        )
        for row in selected_rows
    }

    required_corpus_ids = {
        document_id
        for query_document_ids in relevant_docs.values()
        for document_id in query_document_ids
    }
    missing_corpus_ids = required_corpus_ids - full_corpus.keys()
    if missing_corpus_ids:
        raise RuntimeError(
            "Relevant TechQA documents are missing from the corpus: "
            f"{sorted(missing_corpus_ids)}"
        )

    selected_corpus_ids = _select_corpus_ids(
        corpus_ids=list(full_corpus),
        required_corpus_ids=required_corpus_ids,
        corpus_size=corpus_size,
        rng=rng,
    )
    corpus = {
        document_id: text
        for document_id, text in full_corpus.items()
        if document_id in selected_corpus_ids
    }
    return {
        "dataset_id": TECHQA_DATASET_ID,
        "query_split": normalized_query_split,
        "corpus": corpus,
        "documents": {
            document_id: document_metadata[document_id]
            for document_id in corpus
        },
        "queries": queries,
        "relevant_docs": relevant_docs,
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
    selected_distractors = set(
        rng.choice(
            distractor_ids,
            size=target_size - len(required_corpus_ids),
            replace=False,
        ).tolist()
    )
    return required_corpus_ids | selected_distractors


def _document_metadata(
    document_id: str,
    document_text: str,
) -> dict[str, str]:
    """Split NVIDIA's ``Title: ...\n\nText:\n...`` Technote format."""
    title = document_id
    body = document_text
    if document_text.startswith("Title:"):
        title_block, separator, remainder = document_text.partition("\n\nText:\n")
        title = title_block.removeprefix("Title:").strip() or document_id
        if separator:
            body = remainder.strip()
    return {"id": document_id, "title": title, "body": body}

