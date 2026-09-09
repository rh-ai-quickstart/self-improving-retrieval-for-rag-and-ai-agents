"""In-memory SentenceTransformer and FAISS search engine."""

from __future__ import annotations

import time
from pathlib import Path
from threading import Lock
from typing import Any

import numpy as np
from sentence_transformers import SentenceTransformer

from apps.retrieval_poc.retrieval.chunking import DocumentChunk
from apps.retrieval_poc.retrieval.indexing import load_search_bundle


class SearchEngine:
    """Load one immutable bundle and serve concurrent query requests."""

    def __init__(
        self,
        bundle_path: Path,
        expected_model_id: str = "",
        expected_digest: str = "",
    ) -> None:
        bundle_bytes = bundle_path.read_bytes()
        self.index, self.chunks, self.manifest = load_search_bundle(bundle_bytes)
        self.model_id = str(self.manifest["model_id"])
        self.query_prefix = str(self.manifest.get("query_prefix", ""))
        self.document_prefix = str(self.manifest.get("document_prefix", ""))
        if expected_model_id and expected_model_id != self.model_id:
            raise ValueError(
                f"Configured model {expected_model_id!r} does not match bundle "
                f"model {self.model_id!r}."
            )
        digest = str(self.manifest["bundle_digest"])
        if expected_digest and expected_digest != digest:
            raise ValueError("Configured bundle digest does not match its manifest.")
        self.model = SentenceTransformer(self.model_id, device="cpu")
        self._encode_lock = Lock()

    def search(self, query: str, top_k: int) -> dict[str, Any]:
        normalized_query = query.strip()
        if not normalized_query:
            raise ValueError("query cannot be empty")
        started = time.perf_counter()
        query_vector = self._encode([self.query_prefix + normalized_query])
        scores, indices = self.index.search(query_vector, self.index.ntotal)
        results: list[dict[str, Any]] = []
        seen_documents: set[str] = set()
        for score, index in zip(scores[0], indices[0], strict=True):
            if int(index) < 0:
                continue
            chunk: DocumentChunk = self.chunks[int(index)]
            document_id = chunk["document_id"]
            if document_id in seen_documents:
                continue
            seen_documents.add(document_id)
            results.append(
                {
                    "rank": len(results) + 1,
                    "document_id": document_id,
                    "chunk_id": chunk["chunk_id"],
                    "chunk_index": chunk["chunk_index"],
                    "title": chunk["title"],
                    "snippet": _shorten(chunk["snippet"]),
                    "score": float(score),
                }
            )
            if len(results) == top_k:
                break
        return {
            "query": normalized_query,
            "model_id": self.model_id,
            "bundle_digest": self.manifest["bundle_digest"],
            "elapsed_ms": round((time.perf_counter() - started) * 1_000, 2),
            "results": results,
        }

    def embed(self, texts: list[str], input_type: str) -> np.ndarray:
        prefix = {
            "query": self.query_prefix,
            "document": self.document_prefix,
            "raw": "",
        }[input_type]
        return self._encode([prefix + text for text in texts])

    def _encode(self, texts: list[str]) -> np.ndarray:
        with self._encode_lock:
            embeddings = self.model.encode(
                texts,
                normalize_embeddings=True,
                convert_to_numpy=True,
                show_progress_bar=False,
            )
        vectors = np.ascontiguousarray(embeddings, dtype=np.float32)
        if vectors.shape[1] != self.index.d:
            raise RuntimeError(
                f"Query dimension {vectors.shape[1]} does not match index "
                f"dimension {self.index.d}."
            )
        return vectors


def _shorten(text: str, max_characters: int = 700) -> str:
    if len(text) <= max_characters:
        return text
    shortened = text[: max_characters + 1].rsplit(" ", 1)[0].rstrip()
    return f"{shortened}…"

