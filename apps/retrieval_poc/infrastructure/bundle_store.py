"""Persist versioned search bundles in the active ZenML artifact store."""

from __future__ import annotations

from zenml.client import Client


def publish_search_bundle(bundle_bytes: bytes, digest: str) -> str:
    """Write a content-addressed bundle and return its S3 URI."""
    artifact_store = Client().active_stack.artifact_store
    root = artifact_store.path.rstrip("/")
    if not root.startswith("s3://"):
        raise RuntimeError(
            "Search serving currently requires the OpenShift S3/MinIO "
            f"artifact store; active path is {root!r}."
        )
    uri = f"{root}/search-bundles/{digest}/search-bundle.zip"
    if not artifact_store.exists(uri):
        with artifact_store.open(uri, "wb") as stream:
            stream.write(bundle_bytes)
    return uri

