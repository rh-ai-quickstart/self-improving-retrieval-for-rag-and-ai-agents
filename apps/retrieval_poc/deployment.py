"""Deploy the selected model through OpenShift AI's managed KServe API."""

from __future__ import annotations

import os
import time
from typing import Any

from kubernetes import client, config
from kubernetes.client.exceptions import ApiException
from zenml import step


KSERVE_GROUP = "serving.kserve.io"
KSERVE_VERSION = "v1beta1"
KSERVE_PLURAL = "inferenceservices"


def _current_workload() -> tuple[str, str, str]:
    """Return namespace, service account, and image for this ZenML pod."""
    config.load_incluster_config()
    namespace = open(
        "/var/run/secrets/kubernetes.io/serviceaccount/namespace",
        encoding="utf-8",
    ).read().strip()
    pod_name = os.environ["HOSTNAME"]
    pod = client.CoreV1Api().read_namespaced_pod(pod_name, namespace)

    containers = pod.spec.containers or []
    if not containers:
        raise RuntimeError(f"Pod {namespace}/{pod_name} has no containers")
    source = next(
        (
            container
            for preferred in ("main", "zenml")
            for container in containers
            if container.name == preferred
        ),
        containers[0],
    )
    service_account = pod.spec.service_account_name
    if not service_account or not source.image:
        raise RuntimeError(
            f"Cannot determine service account or image for {namespace}/{pod_name}"
        )
    return namespace, service_account, source.image


def _manifest(
    *,
    name: str,
    namespace: str,
    service_account: str,
    image: str,
    winner: dict[str, Any],
) -> dict[str, Any]:
    environment = {
        "MODEL_ID": str(winner["model_id"]),
        "QUERY_PREFIX": str(winner.get("query_prefix", "")),
        "DOCUMENT_PREFIX": str(winner.get("document_prefix", "")),
        "HOME": "/tmp",
        "XDG_CACHE_HOME": "/tmp/.cache",
        "HF_HOME": "/tmp/.cache/huggingface",
        "HF_HUB_CACHE": "/tmp/.cache/huggingface/hub",
        "TORCH_HOME": "/tmp/.cache/torch",
    }
    return {
        "apiVersion": f"{KSERVE_GROUP}/{KSERVE_VERSION}",
        "kind": "InferenceService",
        "metadata": {
            "name": name,
            "namespace": namespace,
            "labels": {
                "app.kubernetes.io/managed-by": "zenml",
                "app.kubernetes.io/part-of": "retrieval-model-selection",
                "opendatahub.io/dashboard": "true",
            },
            "annotations": {
                "serving.kserve.io/deploymentMode": "RawDeployment",
            },
        },
        "spec": {
            "predictor": {
                "minReplicas": 1,
                "maxReplicas": 1,
                "serviceAccountName": service_account,
                "containers": [
                    {
                        "name": "kserve-container",
                        "image": image,
                        "imagePullPolicy": "IfNotPresent",
                        "command": ["python", "-m", "uvicorn"],
                        "args": [
                            "apps.retrieval_poc.server:app",
                            "--host",
                            "0.0.0.0",
                            "--port",
                            "8080",
                        ],
                        "env": [
                            {"name": key, "value": value}
                            for key, value in environment.items()
                        ],
                        "ports": [
                            {
                                "name": "http1",
                                "containerPort": 8080,
                                "protocol": "TCP",
                            }
                        ],
                        "readinessProbe": {
                            "httpGet": {"path": "/health", "port": 8080},
                            "periodSeconds": 10,
                            "timeoutSeconds": 5,
                            "failureThreshold": 60,
                        },
                        "resources": {
                            "requests": {"cpu": "250m", "memory": "512Mi"},
                            "limits": {"cpu": "2", "memory": "2Gi"},
                        },
                    }
                ],
            }
        },
    }


@step(enable_cache=False)
def deploy_winning_model(
    winner: dict[str, Any],
    deployment_name: str = "retrieval-embedding",
    timeout_seconds: int = 600,
) -> dict[str, Any]:
    """Create or update a KServe InferenceService and wait until it is ready."""
    if timeout_seconds <= 0:
        raise ValueError("timeout_seconds must be positive")

    namespace, service_account, image = _current_workload()
    api = client.CustomObjectsApi()
    body = _manifest(
        name=deployment_name,
        namespace=namespace,
        service_account=service_account,
        image=image,
        winner=winner,
    )

    try:
        api.get_namespaced_custom_object(
            KSERVE_GROUP,
            KSERVE_VERSION,
            namespace,
            KSERVE_PLURAL,
            deployment_name,
        )
    except ApiException as error:
        if error.status != 404:
            raise
        api.create_namespaced_custom_object(
            KSERVE_GROUP,
            KSERVE_VERSION,
            namespace,
            KSERVE_PLURAL,
            body,
        )
        action = "created"
    else:
        api.patch_namespaced_custom_object(
            KSERVE_GROUP,
            KSERVE_VERSION,
            namespace,
            KSERVE_PLURAL,
            deployment_name,
            body,
        )
        action = "updated"

    print(
        f"KServe InferenceService {namespace}/{deployment_name} {action} "
        f"with {winner['model_id']}"
    )
    deadline = time.monotonic() + timeout_seconds
    latest: dict[str, Any] = {}
    while time.monotonic() < deadline:
        latest = api.get_namespaced_custom_object(
            KSERVE_GROUP,
            KSERVE_VERSION,
            namespace,
            KSERVE_PLURAL,
            deployment_name,
        )
        conditions = latest.get("status", {}).get("conditions", [])
        ready = next(
            (
                condition
                for condition in conditions
                if condition.get("type") == "Ready"
            ),
            None,
        )
        if ready and ready.get("status") == "True":
            url = str(latest.get("status", {}).get("url", ""))
            print(f"KServe InferenceService is ready: {url or deployment_name}")
            return {
                "name": deployment_name,
                "namespace": namespace,
                "model_id": winner["model_id"],
                "url": url,
            }
        if ready and ready.get("status") == "False":
            print(
                "KServe is not ready yet: "
                f"{ready.get('reason', 'unknown')} - "
                f"{ready.get('message', 'no message')}"
            )
        time.sleep(5)

    conditions = latest.get("status", {}).get("conditions", [])
    raise TimeoutError(
        f"KServe InferenceService {namespace}/{deployment_name} was not ready "
        f"within {timeout_seconds}s; conditions={conditions}"
    )
