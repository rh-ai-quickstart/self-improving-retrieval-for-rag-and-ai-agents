"""Dynamic ZenML pipeline for TechQA model selection and search deployment."""

from __future__ import annotations

from zenml import pipeline
from zenml.config import DockerSettings
from zenml.config.docker_settings import DockerBuildConfig
from zenml.integrations.kubernetes.flavors.kubernetes_orchestrator_flavor import (
    KubernetesOrchestratorSettings,
)
from zenml.integrations.kubernetes.pod_settings import KubernetesPodSettings

from apps.retrieval_poc.config import MODELS, ModelConfig
from apps.retrieval_poc.pipeline.steps import (
    build_winner_search_index,
    deploy_search_app,
    evaluate_embedding_model,
    prepare_dataset,
    select_best_model,
)


PIPELINE_RUNTIME_ENVIRONMENT = {
    "HOME": "/tmp",
    "XDG_CACHE_HOME": "/tmp/.cache",
    "HF_HOME": "/tmp/.cache/huggingface",
    "HF_DATASETS_CACHE": "/tmp/.cache/huggingface/datasets",
    "HF_HUB_CACHE": "/tmp/.cache/huggingface/hub",
    "TORCH_HOME": "/tmp/.cache/torch",
}
PIPELINE_MAX_PARALLEL_STEPS = 3
PIPELINE_STEP_RESOURCES = {
    "requests": {"cpu": "1", "memory": "2Gi"},
    "limits": {"cpu": "2", "memory": "4Gi"},
}
PIPELINE_ORCHESTRATOR_RESOURCES = {
    "requests": {"cpu": "250m", "memory": "512Mi"},
    "limits": {"cpu": "500m", "memory": "1Gi"},
}


@pipeline(
    dynamic=True,
    enable_cache=False,
    settings={
        "docker": DockerSettings(
            required_integrations=["mlflow", "s3"],
            pyproject_path="apps/pyproject.toml",
            # Compile for the x86_64 OpenShift target with CPU PyTorch. This
            # avoids exporting CUDA transitive dependencies from a host lock.
            pyproject_export_command=[
                "uv",
                "pip",
                "compile",
                "--python-platform",
                "x86_64-manylinux_2_28",
                "--torch-backend",
                "cpu",
                "{directory}/pyproject.toml",
            ],
            local_project_install_command="uv pip install --no-deps ./apps",
            python_package_installer_args={"torch-backend": "cpu"},
            runtime_environment=PIPELINE_RUNTIME_ENVIRONMENT,
            build_config=DockerBuildConfig(dockerignore="apps/.dockerignore"),
        ),
        "orchestrator.kubernetes": KubernetesOrchestratorSettings(
            max_parallelism=PIPELINE_MAX_PARALLEL_STEPS,
            pod_settings=KubernetesPodSettings(resources=PIPELINE_STEP_RESOURCES),
            orchestrator_pod_settings=KubernetesPodSettings(
                resources=PIPELINE_ORCHESTRATOR_RESOURCES
            ),
        ),
    },
)
def retrieval_model_selection_pipeline(
    models: list[ModelConfig] = MODELS,
    num_queries: int = 160,
    corpus_size: int = 500,
    top_k: int = 50,
    seed: int = 42,
    query_split: str = "DEV",
    chunk_size_words: int = 240,
    chunk_overlap_words: int = 40,
    deployment_name: str = "retrieval-embedding",
    deployment_timeout: int = 600,
    minio_endpoint: str = "http://minio:9000",
    minio_secret_name: str = "minio-root",
    minio_client_image: str = (
        "quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z"
    ),
) -> None:
    """Evaluate candidates, index the winner, and deploy the search app."""
    benchmark = prepare_dataset(
        num_queries=num_queries,
        corpus_size=corpus_size,
        seed=seed,
        query_split=query_split,
    )
    futures = [
        evaluate_embedding_model.submit(
            benchmark=benchmark,
            model_config=model_config,
            top_k=top_k,
            chunk_size_words=chunk_size_words,
            chunk_overlap_words=chunk_overlap_words,
        )
        for model_config in models
    ]
    results = [future.load() for future in futures]
    winner = select_best_model(results=results, metric="ndcg_at_10")
    bundle = build_winner_search_index(
        benchmark=benchmark,
        winner=winner,
        chunk_size_words=chunk_size_words,
        chunk_overlap_words=chunk_overlap_words,
    )
    deploy_search_app(
        winner=winner,
        bundle=bundle,
        deployment_name=deployment_name,
        timeout_seconds=deployment_timeout,
        minio_endpoint=minio_endpoint,
        minio_secret_name=minio_secret_name,
        minio_client_image=minio_client_image,
    )
