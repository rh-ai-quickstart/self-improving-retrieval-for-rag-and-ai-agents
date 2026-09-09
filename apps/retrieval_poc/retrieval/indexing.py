"""FAISS index and portable search-bundle construction."""

from __future__ import annotations

import hashlib
import io
import json
import zipfile
from typing import Any

import faiss
import numpy as np
from sentence_transformers import SentenceTransformer

from apps.retrieval_poc.retrieval.chunking import (
    DocumentChunk,
    chunk_benchmark_documents,
)
from apps.retrieval_poc.retrieval.dataset import RetrievalBenchmark


BUNDLE_FORMAT_VERSION = 1


def build_search_bundle(
    benchmark: RetrievalBenchmark,
    winner: dict[str, Any],
    chunk_size_words: int = 240,
    chunk_overlap_words: int = 40,
) -> tuple[bytes, dict[str, Any]]:
    """Encode shared chunks with the winner and package an exact FAISS index."""
    chunks = chunk_benchmark_documents(
        benchmark,
        chunk_size_words=chunk_size_words,
        chunk_overlap_words=chunk_overlap_words,
    )
    model_id = str(winner["model_id"])
    document_prefix = str(winner.get("document_prefix", ""))
    model = SentenceTransformer(model_id, device="cpu")
    embeddings = model.encode(
        [document_prefix + chunk["text"] for chunk in chunks],
        batch_size=int(winner.get("batch_size", 64)),
        normalize_embeddings=True,
        convert_to_numpy=True,
        show_progress_bar=True,
    )
    vectors = np.ascontiguousarray(embeddings, dtype=np.float32)
    index = faiss.IndexFlatIP(int(vectors.shape[1]))
    index.add(vectors)

    index_bytes = faiss.serialize_index(index).tobytes()
    chunks_bytes = json.dumps(
        chunks,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    content_digest = hashlib.sha256(index_bytes + chunks_bytes).hexdigest()
    manifest = {
        "format_version": BUNDLE_FORMAT_VERSION,
        "bundle_digest": content_digest,
        "dataset_id": benchmark["dataset_id"],
        "query_split": benchmark["query_split"],
        "model_id": model_id,
        "query_prefix": str(winner.get("query_prefix", "")),
        "document_prefix": document_prefix,
        "embedding_dimension": int(vectors.shape[1]),
        "document_count": len(benchmark["corpus"]),
        "chunk_count": len(chunks),
        "chunk_size_words": chunk_size_words,
        "chunk_overlap_words": chunk_overlap_words,
        "index_type": "IndexFlatIP",
        "similarity": "cosine",
    }
    bundle_bytes = _deterministic_zip(
        {
            "index.faiss": index_bytes,
            "chunks.json": chunks_bytes,
            "manifest.json": json.dumps(
                manifest,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            ).encode("utf-8"),
        }
    )
    return bundle_bytes, manifest


def load_search_bundle(
    bundle_bytes: bytes,
) -> tuple[Any, list[DocumentChunk], dict[str, Any]]:
    """Load and validate a search bundle without extracting it to disk."""
    with zipfile.ZipFile(io.BytesIO(bundle_bytes)) as archive:
        expected = {"index.faiss", "chunks.json", "manifest.json"}
        missing = expected - set(archive.namelist())
        if missing:
            raise ValueError(f"Search bundle is missing files: {sorted(missing)}")
        index_bytes = archive.read("index.faiss")
        chunks_bytes = archive.read("chunks.json")
        manifest = json.loads(archive.read("manifest.json"))
        chunks = json.loads(chunks_bytes)

    if int(manifest.get("format_version", -1)) != BUNDLE_FORMAT_VERSION:
        raise ValueError("Unsupported search bundle format version.")
    digest = hashlib.sha256(index_bytes + chunks_bytes).hexdigest()
    if digest != manifest.get("bundle_digest"):
        raise ValueError("Search bundle content digest does not match its manifest.")

    index_array = np.frombuffer(index_bytes, dtype=np.uint8)
    index = faiss.deserialize_index(index_array)
    if index.ntotal != len(chunks):
        raise ValueError("FAISS vector count does not match chunk metadata.")
    if index.d != int(manifest["embedding_dimension"]):
        raise ValueError("FAISS dimension does not match the manifest.")
    return index, chunks, manifest


def _deterministic_zip(files: dict[str, bytes]) -> bytes:
    output = io.BytesIO()
    with zipfile.ZipFile(
        output,
        mode="w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=6,
    ) as archive:
        for name, data in sorted(files.items()):
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o644 << 16
            archive.writestr(entry, data)
    return output.getvalue()

