from __future__ import annotations

from zenml import pipeline
from zenml.config import DockerSettings
from zenml.config.docker_settings import DockerBuildConfig
from zenml.integrations.kubernetes.flavors.kubernetes_orchestrator_flavor import (
    KubernetesOrchestratorSettings,
)
from zenml.integrations.kubernetes.pod_settings import KubernetesPodSettings

from apps.retrieval_poc.config import MODELS, ModelConfig
from apps.retrieval_poc.deployment import deploy_winning_model
from apps.retrieval_poc.steps import (
    evaluate_embedding_model,
    prepare_dataset,
    select_best_model,
)


PIPELINE_REQUIREMENTS = [
    "datasets>=4,<5",
    "fastapi>=0.115,<1",
    "kubernetes>=25,<26",
    "numpy>=2,<3",
    "sentence-transformers>=5,<6",
    "torch==2.13.0",
    "uvicorn>=0.30,<1",
]

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
            requirements=PIPELINE_REQUIREMENTS,
            required_integrations=["mlflow"],
            pyproject_path="apps/pyproject.toml",
            # KServe starts this image directly with Uvicorn, outside the
            # normal ZenML entrypoint that downloads pipeline code at runtime.
            # Installing the local project makes apps.retrieval_poc importable in
            # both execution modes and forces ZenML to include it in the image.
            local_project_install_command="uv pip install --no-deps ./apps",
            python_package_installer_args={"torch-backend": "cpu"},
            runtime_environment=PIPELINE_RUNTIME_ENVIRONMENT,
            build_config=DockerBuildConfig(dockerignore="apps/.dockerignore"),
        ),
        "orchestrator.kubernetes": KubernetesOrchestratorSettings(
            max_parallelism=PIPELINE_MAX_PARALLEL_STEPS,
            pod_settings=KubernetesPodSettings(
                resources=PIPELINE_STEP_RESOURCES,
            ),
            orchestrator_pod_settings=KubernetesPodSettings(
                resources=PIPELINE_ORCHESTRATOR_RESOURCES,
            ),
        ),
    },
)
def retrieval_model_selection_pipeline(
    models: list[ModelConfig] = MODELS,
    num_queries: int = 200,
    corpus_size: int = 2500,
    top_k: int = 50,
    seed: int = 42,
    deployment_name: str = "retrieval-embedding",
    deployment_timeout: int = 600,
) -> None:
    """Prepare one benchmark, fan out evaluations, then select the winner."""
    benchmark = prepare_dataset(
        num_queries=num_queries,
        corpus_size=corpus_size,
        seed=seed,
    )

    futures = [
        evaluate_embedding_model.submit(
            benchmark=benchmark,
            model_config=model_config,
            top_k=top_k,
        )
        for model_config in models
    ]

    results = [future.load() for future in futures]

    winner = select_best_model(
        results=results,
        metric="ndcg_at_10",
    )
    deploy_winning_model(
        winner=winner,
        deployment_name=deployment_name,
        timeout_seconds=deployment_timeout,
    )
