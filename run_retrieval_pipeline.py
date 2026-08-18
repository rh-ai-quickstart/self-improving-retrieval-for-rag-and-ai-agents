"""Submit the retrieval model selection pipeline to the active ZenML stack."""

from __future__ import annotations

import os

from retrieval_poc.pipeline import retrieval_model_selection_pipeline


if __name__ == "__main__":
    retrieval_model_selection_pipeline(
        num_queries=int(os.getenv("NUM_QUERIES", "200")),
        corpus_size=int(os.getenv("CORPUS_SIZE", "2500")),
        top_k=int(os.getenv("TOP_K", "50")),
        seed=int(os.getenv("SEED", "42")),
        deployment_name=os.getenv(
            "MODEL_SERVING_NAME",
            "retrieval-embedding",
        ),
        deployment_timeout=int(os.getenv("MODEL_SERVING_TIMEOUT", "600")),
    )
