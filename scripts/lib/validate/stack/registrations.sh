#!/usr/bin/env bash

component_is_registered() {
    local component_command="$1"
    local component_name="$2"
    local label="$3"

    if zenml "${component_command}" describe "${component_name}" >/dev/null 2>&1; then
        pass "${label} is registered: ${component_name}"
    else
        fail "${label} is not registered or accessible: ${component_name}"
    fi
}

validate_stack_check_registrations() {
    section "Checking ZenML registrations"
    if [[ "${ZENML_AVAILABLE}" != true ]]; then
        skip "ZenML registration checks require an authenticated ZenML CLI."
    else
        if zenml service-connector describe "${ZENML_K8S_CONNECTOR}" >/dev/null 2>&1; then
            pass "Kubernetes service connector is registered: ${ZENML_K8S_CONNECTOR}"
            if zenml service-connector verify "${ZENML_K8S_CONNECTOR}" >/dev/null 2>&1; then
                pass "Kubernetes service connector credentials are valid."
            else
                fail "Kubernetes service connector verification failed; its token may have expired."
            fi
        else
            fail "Kubernetes service connector is not registered: ${ZENML_K8S_CONNECTOR}"
        fi

        component_is_registered orchestrator "${ZENML_ORCHESTRATOR}" "Kubernetes orchestrator"
        component_is_registered artifact-store "${ZENML_ARTIFACT_STORE}" "Artifact store"
        component_is_registered container-registry "${ZENML_CONTAINER_REGISTRY}" "Container registry"
        component_is_registered image-builder "${ZENML_IMAGE_BUILDER}" "Local image builder"
        component_is_registered experiment-tracker "${ZENML_EXPERIMENT_TRACKER}" "MLflow experiment tracker"

        if zenml_public_secret_id "${ZENML_ARTIFACT_SECRET}" >/dev/null 2>&1; then
            pass "Artifact-store credential Secret is registered: ${ZENML_ARTIFACT_SECRET}"
        else
            fail "Artifact-store credential Secret is not registered: ${ZENML_ARTIFACT_SECRET}"
        fi

        if zenml stack describe "${ZENML_STACK}" >/dev/null 2>&1; then
            pass "ZenML stack is registered: ${ZENML_STACK}"
        else
            fail "ZenML stack is not registered: ${ZENML_STACK}"
        fi

        if [[ "${PYTHON_AVAILABLE}" == true ]]; then
            if "${ZENML_PYTHON}" - \
                "${ZENML_STACK}" \
                "${ZENML_ORCHESTRATOR}" \
                "${ZENML_ARTIFACT_STORE}" \
                "${ZENML_CONTAINER_REGISTRY}" \
                "${ZENML_IMAGE_BUILDER}" \
                "${ZENML_EXPERIMENT_TRACKER}" \
                "${ZENML_WORKLOAD_NAMESPACE}" \
                "${ZENML_ORCHESTRATOR_SA}" \
                "${REGISTRY_HOST}" \
                "${MINIO_ENDPOINT}" \
                "${MLFLOW_URL}" <<'PY'
import json
import os
import sys

import mlflow

from zenml.client import Client
from zenml.enums import StackComponentType

(
    stack_name,
    orchestrator_name,
    artifact_store_name,
    registry_name,
    image_builder_name,
    experiment_tracker_name,
    namespace,
    service_account,
    registry_host,
    minio_endpoint,
    mlflow_url,
) = sys.argv[1:]

client = Client()
orchestrator = client.get_stack_component(
    StackComponentType.ORCHESTRATOR, orchestrator_name
)
if orchestrator.flavor_name != "kubernetes":
    raise RuntimeError(
        f"orchestrator flavor is {orchestrator.flavor_name!r}; expected 'kubernetes'"
    )
orchestrator_config = orchestrator.configuration
expected_orchestrator_config = {
    "kubernetes_namespace": namespace,
    "service_account_name": service_account,
    "step_pod_service_account_name": service_account,
}
for key, expected in expected_orchestrator_config.items():
    actual = orchestrator_config.get(key)
    if actual != expected:
        raise RuntimeError(
            f"orchestrator {key} is {actual!r}; expected {expected!r}"
        )
if str(orchestrator_config.get("skip_owner_references")).lower() != "true":
    raise RuntimeError("orchestrator skip_owner_references is not true")

artifact_store = client.get_stack_component(
    StackComponentType.ARTIFACT_STORE, artifact_store_name
)
if artifact_store.flavor_name != "s3":
    raise RuntimeError(
        f"artifact-store flavor is {artifact_store.flavor_name!r}; expected 's3'"
    )
client_kwargs = artifact_store.configuration.get("client_kwargs", {})
if isinstance(client_kwargs, str):
    client_kwargs = json.loads(client_kwargs)
endpoint = client_kwargs.get("endpoint_url")
if minio_endpoint and endpoint != minio_endpoint:
    raise RuntimeError(
        f"artifact-store endpoint is {endpoint!r}; expected {minio_endpoint!r}"
    )

registry = client.get_stack_component(
    StackComponentType.CONTAINER_REGISTRY, registry_name
)
if registry.flavor_name != "default":
    raise RuntimeError(
        f"container-registry flavor is {registry.flavor_name!r}; expected 'default'"
    )
expected_registry_uri = f"{registry_host}/{namespace}"
if registry_host and registry.configuration.get("uri") != expected_registry_uri:
    raise RuntimeError(
        "container-registry URI is "
        f"{registry.configuration.get('uri')!r}; expected {expected_registry_uri!r}"
    )

image_builder = client.get_stack_component(
    StackComponentType.IMAGE_BUILDER, image_builder_name
)
if image_builder.flavor_name != "local":
    raise RuntimeError(
        f"image-builder flavor is {image_builder.flavor_name!r}; expected 'local'"
    )

experiment_tracker = client.get_stack_component(
    StackComponentType.EXPERIMENT_TRACKER, experiment_tracker_name
)
if experiment_tracker.flavor_name != "mlflow":
    raise RuntimeError(
        "experiment-tracker flavor is "
        f"{experiment_tracker.flavor_name!r}; expected 'mlflow'"
    )
if mlflow_url and experiment_tracker.configuration.get("tracking_uri") != mlflow_url:
    raise RuntimeError(
        "experiment-tracker tracking_uri is "
        f"{experiment_tracker.configuration.get('tracking_uri')!r}; "
        f"expected {mlflow_url!r}"
    )
expected_mlflow_environment = {"MLFLOW_WORKSPACE": namespace}
tracker_environment = experiment_tracker.environment or {}
for key, expected in expected_mlflow_environment.items():
    actual = tracker_environment.get(key)
    if actual != expected:
        raise RuntimeError(
            f"experiment-tracker environment {key} is {actual!r}; "
            f"expected {expected!r}"
        )

stack = client.get_stack(stack_name)
expected_components = {
    StackComponentType.ORCHESTRATOR: orchestrator_name,
    StackComponentType.ARTIFACT_STORE: artifact_store_name,
    StackComponentType.CONTAINER_REGISTRY: registry_name,
    StackComponentType.IMAGE_BUILDER: image_builder_name,
    StackComponentType.EXPERIMENT_TRACKER: experiment_tracker_name,
}
for component_type, expected_name in expected_components.items():
    actual_names = [
        component.name for component in stack.components.get(component_type, [])
    ]
    if expected_name not in actual_names:
        raise RuntimeError(
            f"stack {component_type.value} is {actual_names!r}; "
            f"expected {expected_name!r}"
        )

if client.get_stack().name != stack_name:
    raise RuntimeError(f"active stack is not {stack_name!r}")

runtime_tracker = client.active_stack.experiment_trackers.get(
    experiment_tracker_name
)
if runtime_tracker is None:
    raise RuntimeError(
        f"active stack cannot load experiment tracker {experiment_tracker_name!r}"
    )
previous_environment = {
    key: os.environ.get(key) for key in expected_mlflow_environment
}
try:
    os.environ.update(expected_mlflow_environment)
    runtime_tracker.configure_mlflow()
    mlflow.search_experiments(max_results=1)
finally:
    for key, value in previous_environment.items():
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value
PY
            then
                pass "ZenML component configuration, stack composition, active stack, and MLflow credentials are correct."
            else
                fail "ZenML registration exists but its effective configuration is incorrect."
            fi
        else
            skip "Effective ZenML configuration checks require ${ZENML_PYTHON}."
        fi
    fi
}
