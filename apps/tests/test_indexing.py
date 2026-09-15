"""Unit tests for FAISS search bundle construction and validation."""

from __future__ import annotations

import json

import pytest

from apps.retrieval_poc.retrieval.indexing import (
    BUNDLE_FORMAT_VERSION,
    _deterministic_zip,
    load_search_bundle,
)


def test_load_search_bundle_round_trip(search_bundle_bytes, search_chunks) -> None:
    index, chunks, manifest = load_search_bundle(search_bundle_bytes)
    assert index.ntotal == 2
    assert chunks == search_chunks
    assert manifest["format_version"] == BUNDLE_FORMAT_VERSION
    assert manifest["bundle_digest"]


def test_load_search_bundle_rejects_missing_files() -> None:
    bundle = _deterministic_zip({"index.faiss": b"data"})
    with pytest.raises(ValueError, match="missing files"):
        load_search_bundle(bundle)


def test_load_search_bundle_rejects_digest_mismatch(search_bundle_bytes) -> None:
    import io
    import zipfile

    with zipfile.ZipFile(io.BytesIO(search_bundle_bytes)) as archive:
        manifest = json.loads(archive.read("manifest.json"))
        manifest["bundle_digest"] = "0" * 64
        tampered = _deterministic_zip(
            {
                "index.faiss": archive.read("index.faiss"),
                "chunks.json": archive.read("chunks.json"),
                "manifest.json": json.dumps(manifest).encode(),
            }
        )
    with pytest.raises(ValueError, match="content digest does not match"):
        load_search_bundle(tampered)


def test_load_search_bundle_rejects_unsupported_format(search_bundle_bytes) -> None:
    import io
    import zipfile

    with zipfile.ZipFile(io.BytesIO(search_bundle_bytes)) as archive:
        manifest = json.loads(archive.read("manifest.json"))
        manifest["format_version"] = 99
        tampered = _deterministic_zip(
            {
                "index.faiss": archive.read("index.faiss"),
                "chunks.json": archive.read("chunks.json"),
                "manifest.json": json.dumps(manifest).encode(),
            }
        )
    with pytest.raises(ValueError, match="Unsupported search bundle format"):
        load_search_bundle(tampered)
