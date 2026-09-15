"""Unit tests for the FastAPI search application."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from apps.retrieval_poc.search_app import app as app_module


@pytest.fixture
def api_client(search_engine, monkeypatch):
    monkeypatch.setattr(
        app_module,
        "SearchEngine",
        lambda *_args, **_kwargs: search_engine,
    )
    with TestClient(app_module.app) as client:
        yield client


def test_health_reports_bundle_metadata(api_client) -> None:
    response = api_client.get("/health")
    assert response.status_code == 200
    payload = response.json()
    assert payload["status"] == "ready"
    assert payload["model_id"] == "fake/model"
    assert payload["document_count"] == 2


def test_search_returns_ranked_documents(api_client) -> None:
    response = api_client.post(
        "/search",
        json={"query": "database failure", "top_k": 2},
    )
    assert response.status_code == 200
    payload = response.json()
    assert payload["query"] == "database failure"
    assert [item["document_id"] for item in payload["results"]] == [
        "db",
        "network",
    ]


def test_search_rejects_empty_query(api_client) -> None:
    response = api_client.post("/search", json={"query": "   ", "top_k": 1})
    assert response.status_code == 422


def test_embed_returns_vectors(api_client) -> None:
    response = api_client.post(
        "/embed",
        json={"inputs": ["database failure"], "input_type": "query"},
    )
    assert response.status_code == 200
    payload = response.json()
    assert payload["input_type"] == "query"
    assert payload["embeddings"] == [[1.0, 0.0]]


def test_embed_rejects_empty_inputs(api_client) -> None:
    response = api_client.post("/embed", json={"inputs": [], "input_type": "raw"})
    assert response.status_code == 422


def test_index_serves_ui(api_client) -> None:
    response = api_client.get("/")
    assert response.status_code == 200
    assert "text/html" in response.headers["content-type"]
