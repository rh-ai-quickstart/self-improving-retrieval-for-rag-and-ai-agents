"""Unit tests for candidate model configuration."""

from __future__ import annotations

from apps.retrieval_poc.config import MODELS, ModelConfig


def test_models_include_expected_candidates() -> None:
    model_ids = {model.model_id for model in MODELS}
    assert "sentence-transformers/all-MiniLM-L6-v2" in model_ids
    assert "BAAI/bge-small-en-v1.5" in model_ids
    assert "intfloat/e5-small-v2" in model_ids


def test_prefix_models_define_query_or_document_prefixes() -> None:
    by_id = {model.model_id: model for model in MODELS}
    assert by_id["BAAI/bge-small-en-v1.5"].query_prefix
    assert by_id["intfloat/e5-small-v2"].query_prefix
    assert by_id["intfloat/e5-small-v2"].document_prefix


def test_model_config_is_immutable() -> None:
    model = ModelConfig(model_id="example/model", batch_size=32)
    assert model.batch_size == 32
    assert model.query_prefix == ""
