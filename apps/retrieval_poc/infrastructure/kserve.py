"""Deploy the search bundle and UI through OpenShift AI KServe."""

from __future__ import annotations

import os
import time
from typing import Any
from urllib.parse import urlparse

from kubernetes import client, config
from kubernetes.client.exceptions import ApiException


KSERVE_GROUP = "serving.kserve.io"
KSERVE_VERSION = "v1beta1"
KSERVE_PLURAL = "inferenceservices"
ROUTE_GROUP = "route.openshift.io"
ROUTE_VERSION = "v1"
ROUTE_PLURAL = "routes"


def deploy_search_service(
    *,
    winner: dict[str, Any],
    bundle: dict[str, Any],
    deployment_name: str,
    timeout_seconds: int,
    minio_endpoint: str,
    minio_secret_name: str,
    minio_client_image: str,
) -> dict[str, Any]:
    """Create or update KServe and expose its browser UI with a TLS Route."""
    if timeout_seconds <= 0:
        raise ValueError("timeout_seconds must be positive")
    namespace, service_account, image = _current_workload()
    bucket, object_key = _split_s3_uri(str(bundle["bundle_uri"]))
    custom_api = client.CustomObjectsApi()
    body = _inference_manifest(
        name=deployment_name,
        namespace=namespace,
        service_account=service_account,
        image=image,
        winner=winner,
        bundle=bundle,
        minio_endpoint=minio_endpoint,
        minio_secret_name=minio_secret_name,
        minio_client_image=minio_client_image,
        bucket=bucket,
        object_key=object_key,
    )
    action = _apply_custom_object(
        api=custom_api,
        group=KSERVE_GROUP,
        version=KSERVE_VERSION,
        namespace=namespace,
        plural=KSERVE_PLURAL,
        name=deployment_name,
        body=body,
    )
    print(
        f"KServe InferenceService {namespace}/{deployment_name} {action} "
        f"with {winner['model_id']}"
    )
    inference = _wait_for_inference_service(
        custom_api, namespace, deployment_name, timeout_seconds
    )
    _wait_for_ready_predictor(
        namespace=namespace,
        deployment_name=deployment_name,
        bundle_digest=str(bundle["bundle_digest"]),
        image=image,
        timeout_seconds=timeout_seconds,
    )
    service_name = _predictor_service_name(namespace, deployment_name)
    route_name = _route_name(deployment_name)
    route_body = _route_manifest(route_name, namespace, service_name)
    route_action = _apply_custom_object(
        api=custom_api,
        group=ROUTE_GROUP,
        version=ROUTE_VERSION,
        namespace=namespace,
        plural=ROUTE_PLURAL,
        name=route_name,
        body=route_body,
    )
    print(
        f"OpenShift Route {namespace}/{route_name} {route_action} "
        f"for Service {service_name}"
    )
    ui_url = _wait_for_route(
        custom_api, namespace, route_name, timeout_seconds
    )
    _confirm_route(custom_api, namespace, route_name, ui_url)
    internal_url = str(inference.get("status", {}).get("url", ""))
    print(f"Search UI is ready: {ui_url}")
    return {
        "name": deployment_name,
        "namespace": namespace,
        "model_id": winner["model_id"],
        "bundle_digest": bundle["bundle_digest"],
        "bundle_uri": bundle["bundle_uri"],
        "ui_url": ui_url,
        "api_docs_url": f"{ui_url}/docs",
        "health_url": f"{ui_url}/health",
        "internal_kserve_url": internal_url,
    }


def _current_workload() -> tuple[str, str, str]:
    config.load_incluster_config()
    with open(
        "/var/run/secrets/kubernetes.io/serviceaccount/namespace",
        encoding="utf-8",
    ) as stream:
        namespace = stream.read().strip()
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


def _split_s3_uri(uri: str) -> tuple[str, str]:
    parsed = urlparse(uri)
    if parsed.scheme != "s3" or not parsed.netloc or not parsed.path.lstrip("/"):
        raise ValueError(f"Invalid search bundle S3 URI: {uri!r}")
    return parsed.netloc, parsed.path.lstrip("/")


def _inference_manifest(
    *,
    name: str,
    namespace: str,
    service_account: str,
    image: str,
    winner: dict[str, Any],
    bundle: dict[str, Any],
    minio_endpoint: str,
    minio_secret_name: str,
    minio_client_image: str,
    bucket: str,
    object_key: str,
) -> dict[str, Any]:
    runtime_environment = {
        "MODEL_ID": str(winner["model_id"]),
        "QUERY_PREFIX": str(winner.get("query_prefix", "")),
        "DOCUMENT_PREFIX": str(winner.get("document_prefix", "")),
        "SEARCH_BUNDLE_PATH": "/opt/search-bundle/search-bundle.zip",
        "SEARCH_BUNDLE_DIGEST": str(bundle["bundle_digest"]),
        "HOME": "/tmp",
        "XDG_CACHE_HOME": "/tmp/.cache",
        "HF_HOME": "/tmp/.cache/huggingface",
        "HF_HUB_CACHE": "/tmp/.cache/huggingface/hub",
        "TORCH_HOME": "/tmp/.cache/torch",
    }
    secret_user = {
        "name": "MINIO_ROOT_USER",
        "valueFrom": {
            "secretKeyRef": {
                "name": minio_secret_name,
                "key": "MINIO_ROOT_USER",
            }
        },
    }
    secret_password = {
        "name": "MINIO_ROOT_PASSWORD",
        "valueFrom": {
            "secretKeyRef": {
                "name": minio_secret_name,
                "key": "MINIO_ROOT_PASSWORD",
            }
        },
    }
    return {
        "apiVersion": f"{KSERVE_GROUP}/{KSERVE_VERSION}",
        "kind": "InferenceService",
        "metadata": {
            "name": name,
            "namespace": namespace,
            "labels": {
                "app.kubernetes.io/managed-by": "zenml",
                "app.kubernetes.io/part-of": "techqa-semantic-search",
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
                "volumes": [{"name": "search-bundle", "emptyDir": {}}],
                "initContainers": [
                    {
                        "name": "download-search-bundle",
                        "image": minio_client_image,
                        "command": ["/bin/sh", "-ec"],
                        "args": [
                            "mc alias set source \"$MINIO_ENDPOINT\" "
                            "\"$MINIO_ROOT_USER\" \"$MINIO_ROOT_PASSWORD\"; "
                            "mc cp \"source/$MINIO_BUCKET/$MINIO_OBJECT_KEY\" "
                            "/bundle/search-bundle.zip"
                        ],
                        "env": [
                            {"name": "MC_CONFIG_DIR", "value": "/tmp/.mc"},
                            {"name": "MINIO_ENDPOINT", "value": minio_endpoint},
                            {"name": "MINIO_BUCKET", "value": bucket},
                            {"name": "MINIO_OBJECT_KEY", "value": object_key},
                            secret_user,
                            secret_password,
                        ],
                        "volumeMounts": [
                            {"name": "search-bundle", "mountPath": "/bundle"}
                        ],
                        "securityContext": {
                            "runAsNonRoot": True,
                            "allowPrivilegeEscalation": False,
                            "capabilities": {"drop": ["ALL"]},
                        },
                    }
                ],
                "containers": [
                    {
                        "name": "kserve-container",
                        "image": image,
                        "imagePullPolicy": "IfNotPresent",
                        "command": ["python", "-m", "uvicorn"],
                        "args": [
                            "apps.retrieval_poc.search_app.app:app",
                            "--host",
                            "0.0.0.0",
                            "--port",
                            "8080",
                        ],
                        "env": [
                            {"name": key, "value": value}
                            for key, value in runtime_environment.items()
                        ],
                        "volumeMounts": [
                            {
                                "name": "search-bundle",
                                "mountPath": "/opt/search-bundle",
                                "readOnly": True,
                            }
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
                            "requests": {"cpu": "250m", "memory": "1Gi"},
                            "limits": {"cpu": "2", "memory": "3Gi"},
                        },
                    }
                ],
            }
        },
    }


def _route_name(deployment_name: str) -> str:
    """Return a Route name that does not collide with the InferenceService."""
    return f"{deployment_name}-ui"


def _route_manifest(name: str, namespace: str, service: str) -> dict[str, Any]:
    return {
        "apiVersion": f"{ROUTE_GROUP}/{ROUTE_VERSION}",
        "kind": "Route",
        "metadata": {
            "name": name,
            "namespace": namespace,
            "labels": {
                "app.kubernetes.io/managed-by": "zenml",
                "app.kubernetes.io/part-of": "techqa-semantic-search",
            },
        },
        "spec": {
            "to": {"kind": "Service", "name": service, "weight": 100},
            "port": {"targetPort": "http1"},
            "tls": {
                "termination": "edge",
                "insecureEdgeTerminationPolicy": "Redirect",
            },
            "wildcardPolicy": "None",
        },
    }


def _apply_custom_object(
    *,
    api: client.CustomObjectsApi,
    group: str,
    version: str,
    namespace: str,
    plural: str,
    name: str,
    body: dict[str, Any],
) -> str:
    try:
        api.get_namespaced_custom_object(group, version, namespace, plural, name)
    except ApiException as error:
        if error.status != 404:
            raise
        api.create_namespaced_custom_object(
            group, version, namespace, plural, body
        )
        return "created"
    api.patch_namespaced_custom_object(
        group, version, namespace, plural, name, body
    )
    return "updated"


def _wait_for_inference_service(
    api: client.CustomObjectsApi,
    namespace: str,
    name: str,
    timeout_seconds: int,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout_seconds
    latest: dict[str, Any] = {}
    while time.monotonic() < deadline:
        latest = api.get_namespaced_custom_object(
            KSERVE_GROUP, KSERVE_VERSION, namespace, KSERVE_PLURAL, name
        )
        conditions = latest.get("status", {}).get("conditions", [])
        ready = next(
            (condition for condition in conditions if condition.get("type") == "Ready"),
            None,
        )
        if ready and ready.get("status") == "True":
            return latest
        if ready and ready.get("status") == "False":
            print(
                "KServe is not ready yet: "
                f"{ready.get('reason', 'unknown')} - "
                f"{ready.get('message', 'no message')}"
            )
        time.sleep(5)
    raise TimeoutError(
        f"KServe InferenceService {namespace}/{name} was not ready within "
        f"{timeout_seconds}s; conditions={latest.get('status', {}).get('conditions', [])}"
    )


def _predictor_service_name(namespace: str, deployment_name: str) -> str:
    core = client.CoreV1Api()
    preferred = f"{deployment_name}-predictor"
    try:
        core.read_namespaced_service(preferred, namespace)
        return preferred
    except ApiException as error:
        if error.status != 404:
            raise
    services = core.list_namespaced_service(
        namespace,
        label_selector=f"serving.kserve.io/inferenceservice={deployment_name}",
    ).items
    if not services:
        raise RuntimeError(
            f"No predictor Service was created for {namespace}/{deployment_name}."
        )
    return str(services[0].metadata.name)


def _wait_for_ready_predictor(
    *,
    namespace: str,
    deployment_name: str,
    bundle_digest: str,
    image: str,
    timeout_seconds: int,
) -> None:
    """Wait until a ready predictor pod is running the requested bundle."""
    core = client.CoreV1Api()
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        pods = core.list_namespaced_pod(
            namespace,
            label_selector=(
                f"serving.kserve.io/inferenceservice={deployment_name}"
            ),
        ).items
        for pod in pods:
            container = next(
                (
                    item
                    for item in (pod.spec.containers or [])
                    if item.name == "kserve-container"
                ),
                None,
            )
            if container is None:
                continue
            environment = {
                item.name: item.value
                for item in (container.env or [])
                if item.value is not None
            }
            conditions = {
                condition.type: condition.status
                for condition in (pod.status.conditions or [])
            }
            if (
                environment.get("SEARCH_BUNDLE_DIGEST") == bundle_digest
                and container.image == image
                and pod.status.phase == "Running"
                and conditions.get("Ready") == "True"
            ):
                return
        time.sleep(3)
    raise TimeoutError(
        f"No ready predictor pod for {namespace}/{deployment_name} loaded "
        f"bundle {bundle_digest} within {timeout_seconds}s."
    )


def _confirm_route(
    api: client.CustomObjectsApi,
    namespace: str,
    name: str,
    ui_url: str,
) -> None:
    """Fail the deploy step if the Route object is not still present."""
    route = api.get_namespaced_custom_object(
        ROUTE_GROUP, ROUTE_VERSION, namespace, ROUTE_PLURAL, name
    )
    expected_host = ui_url.removeprefix("https://")
    hosts = [
        ingress.get("host")
        for ingress in route.get("status", {}).get("ingress", [])
        if ingress.get("host")
    ]
    if expected_host not in hosts:
        raise RuntimeError(
            f"OpenShift Route {namespace}/{name} is missing admitted host "
            f"{expected_host}; ingress hosts={hosts!r}"
        )


def _wait_for_route(
    api: client.CustomObjectsApi,
    namespace: str,
    name: str,
    timeout_seconds: int,
) -> str:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        route = api.get_namespaced_custom_object(
            ROUTE_GROUP, ROUTE_VERSION, namespace, ROUTE_PLURAL, name
        )
        for ingress in route.get("status", {}).get("ingress", []):
            admitted = next(
                (
                    condition
                    for condition in ingress.get("conditions", [])
                    if condition.get("type") == "Admitted"
                    and condition.get("status") == "True"
                ),
                None,
            )
            host = ingress.get("host")
            if admitted and host:
                return f"https://{host}"
        time.sleep(2)
    raise TimeoutError(
        f"OpenShift Route {namespace}/{name} was not admitted within "
        f"{timeout_seconds}s."
    )
