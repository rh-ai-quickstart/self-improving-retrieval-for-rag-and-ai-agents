"""Unit tests for HTTP request and response schemas."""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from apps.retrieval_poc.search_app.schemas import (
    EmbeddingRequest,
    SearchRequest,
)


def test_search_request_defaults() -> None:
    request = SearchRequest(query="database failure")
    assert request.top_k == 5


def test_search_request_rejects_empty_query() -> None:
    with pytest.raises(ValidationError):
        SearchRequest(query="")


def test_search_request_rejects_invalid_top_k() -> None:
    with pytest.raises(ValidationError):
        SearchRequest(query="database failure", top_k=0)
    with pytest.raises(ValidationError):
        SearchRequest(query="database failure", top_k=25)


def test_embedding_request_accepts_string_or_list() -> None:
    single = EmbeddingRequest(inputs="one query")
    batch = EmbeddingRequest(inputs=["one", "two"], input_type="document")
    assert single.input_type == "raw"
    assert batch.input_type == "document"
