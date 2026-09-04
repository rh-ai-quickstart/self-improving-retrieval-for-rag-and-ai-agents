"""Submit the retrieval model selection pipeline to the active ZenML stack."""

from __future__ import annotations

import argparse
import os
from pathlib import Path

from zenml.utils import source_utils


SMOKE_NUM_QUERIES = 20
SMOKE_CORPUS_SIZE = 40
SMOKE_TOP_K = 20


def _configure_source_root() -> Path:
    """Keep the repository package layout in ZenML build contexts."""
    project_root = Path(__file__).resolve().parents[2]
    pyproject_path = project_root / "apps" / "pyproject.toml"
    if not pyproject_path.is_file():
        raise RuntimeError(
            f"Could not locate the application project at {pyproject_path}."
        )

    source_utils.set_custom_source_root(str(project_root))
    return project_root


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Evaluate embedding models and deploy the winning search app."
    )
    parser.add_argument(
        "--smoke",
        action="store_true",
        help=(
            "Run a small TechQA profile (20 queries, 40 documents, top-k 20) "
            "for fast end-to-end validation."
        ),
    )
    return parser.parse_args()


def main() -> None:
    """Configure the source tree and submit the retrieval pipeline."""
    args = _parse_args()
    _configure_source_root()

    # Configure the source root before importing the decorated pipeline. This
    # makes ZenML copy ``apps/`` into /app instead of flattening
    # ``apps/retrieval_poc`` into the image root.
    from .pipeline.definition import retrieval_model_selection_pipeline

    num_queries = (
        SMOKE_NUM_QUERIES
        if args.smoke
        else int(os.getenv("NUM_QUERIES", "160"))
    )
    corpus_size = (
        SMOKE_CORPUS_SIZE
        if args.smoke
        else int(os.getenv("CORPUS_SIZE", "500"))
    )
    top_k = SMOKE_TOP_K if args.smoke else int(os.getenv("TOP_K", "50"))
    profile = "smoke" if args.smoke else "configured"
    print(
        f"Submitting {profile} pipeline profile: "
        f"queries={num_queries}, corpus={corpus_size}, top_k={top_k}"
    )

    retrieval_model_selection_pipeline(
        num_queries=num_queries,
        corpus_size=corpus_size,
        top_k=top_k,
        seed=int(os.getenv("SEED", "42")),
        query_split=os.getenv("QUERY_SPLIT", "DEV"),
        chunk_size_words=int(os.getenv("CHUNK_SIZE_WORDS", "240")),
        chunk_overlap_words=int(os.getenv("CHUNK_OVERLAP_WORDS", "40")),
        deployment_name=os.getenv(
            "MODEL_SERVING_NAME",
            "retrieval-embedding",
        ),
        deployment_timeout=int(os.getenv("MODEL_SERVING_TIMEOUT", "600")),
        minio_endpoint=os.getenv("MINIO_ENDPOINT", "http://minio:9000"),
        minio_secret_name=os.getenv("MINIO_SECRET_NAME", "minio-root"),
        minio_client_image=os.getenv(
            "MINIO_CLIENT_IMAGE",
            "quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z",
        ),
    )


if __name__ == "__main__":
    main()
