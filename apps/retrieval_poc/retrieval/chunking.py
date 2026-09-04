"""Deterministic document chunking for evaluation and search serving."""

from __future__ import annotations

import re
from typing import Any, TypedDict

from apps.retrieval_poc.retrieval.dataset import RetrievalBenchmark


class DocumentChunk(TypedDict):
    """A searchable passage and the document metadata needed by the UI."""

    chunk_id: str
    document_id: str
    chunk_index: int
    title: str
    text: str
    snippet: str


def chunk_benchmark_documents(
    benchmark: RetrievalBenchmark,
    chunk_size_words: int = 240,
    chunk_overlap_words: int = 40,
) -> list[DocumentChunk]:
    """Chunk every benchmark document with its title prepended.

    Whitespace-delimited words are used instead of a model-specific tokenizer
    so every candidate is evaluated against exactly the same passages.
    """
    if chunk_size_words <= 0:
        raise ValueError("chunk_size_words must be positive.")
    if chunk_overlap_words < 0:
        raise ValueError("chunk_overlap_words cannot be negative.")
    if chunk_overlap_words >= chunk_size_words:
        raise ValueError("chunk_overlap_words must be smaller than chunk_size_words.")

    chunks: list[DocumentChunk] = []
    documents: dict[str, dict[str, Any]] = benchmark["documents"]
    for document_id in benchmark["corpus"]:
        document = documents[document_id]
        title = str(document["title"]).strip() or document_id
        body = str(document["body"]).strip()
        words = re.findall(r"\S+", body)
        if not words:
            words = [title]

        step = chunk_size_words - chunk_overlap_words
        for chunk_index, start in enumerate(range(0, len(words), step)):
            chunk_words = words[start : start + chunk_size_words]
            if not chunk_words:
                break
            snippet = " ".join(chunk_words)
            chunks.append(
                {
                    "chunk_id": f"{document_id}::{chunk_index}",
                    "document_id": document_id,
                    "chunk_index": chunk_index,
                    "title": title,
                    "text": f"{title}\n\n{snippet}",
                    "snippet": snippet,
                }
            )
            if start + chunk_size_words >= len(words):
                break

    if not chunks:
        raise RuntimeError("Document chunking produced no searchable passages.")
    return chunks


def collapse_chunk_ranking(
    ranked_chunk_indices: list[int],
    chunks: list[DocumentChunk],
    limit: int,
) -> list[str]:
    """Return the first occurrence of each document in a chunk ranking."""
    if limit <= 0:
        raise ValueError("limit must be positive.")

    ranked_documents: list[str] = []
    seen: set[str] = set()
    for index in ranked_chunk_indices:
        document_id = chunks[index]["document_id"]
        if document_id in seen:
            continue
        seen.add(document_id)
        ranked_documents.append(document_id)
        if len(ranked_documents) == limit:
            break
    return ranked_documents

