#!/usr/bin/env bash
set -uo pipefail

# Validate the remote ZenML workload stack without changing OpenShift or ZenML.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${1:-${REPO_ROOT}/deployment.env}"
FAILURES=0

# shellcheck source=stack_common.sh
source "${SCRIPT_DIR}/stack_common.sh"

pass() {
    echo "    PASS: $1"
}

fail() {
    echo "    FAIL: $1" >&2
    FAILURES=$((FAILURES + 1))
}

skip() {
    echo "    SKIP: $1"
}

command_available() {
    if command -v "$1" >/dev/null 2>&1; then
        pass "Required command available: $1"
        return 0
    fi

    fail "Required command not found: $1"
    return 1
}

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

section "Loading workload-stack validation configuration"
load_stack_config "${CONFIG_FILE}"
info "Workload project: ${ZENML_WORKLOAD_NAMESPACE}"
info "ZenML stack:      ${ZENML_STACK}"

section "Checking local clients and authenticated services"
OC_AVAILABLE=false
CURL_AVAILABLE=false
DOCKER_AVAILABLE=false
ZENML_AVAILABLE=false
PYTHON_AVAILABLE=false

command_available oc && OC_AVAILABLE=true
command_available curl && CURL_AVAILABLE=true
command_available docker && DOCKER_AVAILABLE=true
command_available zenml && ZENML_AVAILABLE=true
command_available "${ZENML_PYTHON}" && PYTHON_AVAILABLE=true

if [[ "${OC_AVAILABLE}" == true ]] && OPENSHIFT_USER="$(oc whoami 2>/dev/null)"; then
    pass "Authenticated to OpenShift as ${OPENSHIFT_USER}"
else
    fail "The oc CLI is not authenticated to OpenShift."
    OC_AVAILABLE=false
fi

if [[ "${ZENML_AVAILABLE}" == true ]] && zenml status >/dev/null 2>&1; then
    pass "The ZenML CLI is authenticated."
else
    fail "The ZenML CLI is not authenticated to the deployed server."
    ZENML_AVAILABLE=false
fi

if [[ "${DOCKER_AVAILABLE}" == true ]] && docker info >/dev/null 2>&1; then
    pass "The local Docker daemon is reachable."
else
    fail "The local Docker daemon is not reachable."
    DOCKER_AVAILABLE=false
fi

if [[ "${PYTHON_AVAILABLE}" == true ]]; then
    CLIENT_VERSION="$("${ZENML_PYTHON}" -c 'import zenml; print(zenml.__version__)' 2>/dev/null || true)"
    if [[ "${CLIENT_VERSION}" == "${ZENML_VERSION}" ]]; then
        pass "ZenML Python client matches the configured server version: ${ZENML_VERSION}"
    else
        fail "ZenML Python client version is ${CLIENT_VERSION:-unavailable}; expected ${ZENML_VERSION}."
    fi

    if "${ZENML_PYTHON}" -c 'import docker; assert docker.from_env().ping()' >/dev/null 2>&1; then
        pass "The ZenML Python environment can reach Docker through the Docker SDK."
    else
        fail "The ZenML Python environment cannot reach Docker through the Docker SDK."
    fi

    MLFLOW_VERSION="$("${ZENML_PYTHON}" -c 'import mlflow; print(mlflow.__version__)' 2>/dev/null || true)"
    if [[ -n "${MLFLOW_VERSION}" ]]; then
        pass "ZenML-managed MLflow SDK is installed: ${MLFLOW_VERSION}"
    else
        fail "MLflow SDK is unavailable. Run 'just bootstrap-stack' to install the ZenML MLflow integration."
    fi
fi

section "Checking the dedicated workload project and permissions"
PROJECT_EXISTS=false
if [[ "${OC_AVAILABLE}" != true ]]; then
    skip "OpenShift resource checks require an authenticated oc CLI."
elif oc get project "${ZENML_WORKLOAD_NAMESPACE}" >/dev/null 2>&1; then
    PROJECT_EXISTS=true
    pass "Project exists: ${ZENML_WORKLOAD_NAMESPACE}"
else
    fail "Project does not exist or is not accessible: ${ZENML_WORKLOAD_NAMESPACE}"
fi

if [[ "${PROJECT_EXISTS}" == true ]]; then
    if oc get serviceaccount "${ZENML_ORCHESTRATOR_SA}" -n "${ZENML_WORKLOAD_NAMESPACE}" >/dev/null 2>&1; then
        pass "Orchestrator service account exists: ${ZENML_ORCHESTRATOR_SA}"
    else
        fail "Orchestrator service account was not found: ${ZENML_ORCHESTRATOR_SA}"
    fi

    for resource in pods jobs; do
        if [[ "$(oc auth can-i create "${resource}" --as="system:serviceaccount:${ZENML_WORKLOAD_NAMESPACE}:${ZENML_ORCHESTRATOR_SA}" -n "${ZENML_WORKLOAD_NAMESPACE}" 2>/dev/null)" == yes ]]; then
            pass "Orchestrator service account can create ${resource}."
        else
            fail "Orchestrator service account cannot create ${resource}."
        fi
    done

    if [[ "$(oc auth can-i update imagestreams/layers --as="system:serviceaccount:${ZENML_WORKLOAD_NAMESPACE}:${ZENML_ORCHESTRATOR_SA}" -n "${ZENML_WORKLOAD_NAMESPACE}" 2>/dev/null)" == yes ]]; then
        pass "Orchestrator service account can push images to its project."
    else
        fail "Orchestrator service account cannot push images to its project."
    fi

    LINKED_PULL_SECRETS="$(oc get serviceaccount "${ZENML_ORCHESTRATOR_SA}" -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{range .imagePullSecrets[*]}{.name}{"\n"}{end}' 2>/dev/null || true)"
    if grep -Fxq "${ZENML_REGISTRY_PULL_SECRET}" <<< "${LINKED_PULL_SECRETS}"; then
        pass "Registry pull Secret is linked to the orchestrator service account."
    else
        fail "Registry pull Secret is not linked: ${ZENML_REGISTRY_PULL_SECRET}"
    fi
fi

section "Checking OpenShift AI KServe deployment capability"
if [[ "${OC_AVAILABLE}" != true ]]; then
    skip "KServe checks require an authenticated oc CLI."
else
    KSERVE_STATE="$(oc get datasciencecluster "${OPENSHIFT_AI_DSC}" -o jsonpath='{.spec.components.kserve.managementState}' 2>/dev/null || true)"
    if [[ "${KSERVE_STATE}" == Managed ]]; then
        pass "OpenShift AI KServe is Managed."
    else
        fail "OpenShift AI KServe state is ${KSERVE_STATE:-unavailable}; expected Managed."
    fi

    if oc get crd inferenceservices.serving.kserve.io >/dev/null 2>&1; then
        pass "KServe InferenceService CRD is installed."
    else
        fail "KServe InferenceService CRD is not installed."
    fi

    if [[ "${PROJECT_EXISTS}" == true ]]; then
        KSERVE_ROLE_REF="$(oc get rolebinding "${MODEL_SERVING_ROLE_BINDING}" -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{.roleRef.kind}:{.roleRef.name}' 2>/dev/null || true)"
        KSERVE_ROLE_SUBJECTS="$(oc get rolebinding "${MODEL_SERVING_ROLE_BINDING}" -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{range .subjects[*]}{.kind}:{.namespace}:{.name}{"\n"}{end}' 2>/dev/null || true)"
        if [[ "${KSERVE_ROLE_REF}" == "Role:${MODEL_SERVING_ROLE}" ]] \
            && grep -Fxq "ServiceAccount:${ZENML_WORKLOAD_NAMESPACE}:${ZENML_ORCHESTRATOR_SA}" <<< "${KSERVE_ROLE_SUBJECTS}"; then
            pass "KServe deployment RoleBinding targets the orchestrator service account."
        else
            fail "KServe deployment RoleBinding is missing or incorrectly configured: ${MODEL_SERVING_ROLE_BINDING}"
        fi

        for verb in get create patch delete; do
            if [[ "$(oc auth can-i "${verb}" inferenceservices.serving.kserve.io --as="system:serviceaccount:${ZENML_WORKLOAD_NAMESPACE}:${ZENML_ORCHESTRATOR_SA}" -n "${ZENML_WORKLOAD_NAMESPACE}" 2>/dev/null)" == yes ]]; then
                pass "Orchestrator service account can ${verb} KServe InferenceServices."
            else
                fail "Orchestrator service account cannot ${verb} KServe InferenceServices."
            fi
        done
    fi
fi

section "Checking the shared OpenShift AI MLflow instance"
MLFLOW_URL=""
if [[ "${OC_AVAILABLE}" != true ]]; then
    skip "MLflow resource checks require an authenticated oc CLI."
else
    MLFLOW_OPERATOR_STATE="$(oc get datasciencecluster "${OPENSHIFT_AI_DSC}" -o jsonpath='{.spec.components.mlflowoperator.managementState}' 2>/dev/null || true)"
    if [[ "${MLFLOW_OPERATOR_STATE}" == Managed ]]; then
        pass "OpenShift AI MLflow operator is Managed."
    else
        fail "OpenShift AI MLflow operator state is ${MLFLOW_OPERATOR_STATE:-unavailable}; expected Managed."
    fi

    MLFLOW_AVAILABLE="$(oc get mlflow "${MLFLOW_INSTANCE}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
    MLFLOW_URL="$(oc get mlflow "${MLFLOW_INSTANCE}" -o jsonpath='{.status.url}' 2>/dev/null || true)"
    if [[ "${MLFLOW_AVAILABLE}" == True ]]; then
        pass "Cluster-scoped MLflow instance is available: ${MLFLOW_INSTANCE}"
    else
        fail "MLflow instance ${MLFLOW_INSTANCE} is missing or not Available."
    fi
    MLFLOW_DESIRED="$(oc get deployment "${MLFLOW_INSTANCE}" -n "${OPENSHIFT_AI_APPLICATIONS_NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
    MLFLOW_DEPLOYMENT_AVAILABLE="$(oc get deployment "${MLFLOW_INSTANCE}" -n "${OPENSHIFT_AI_APPLICATIONS_NAMESPACE}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
    if [[ -n "${MLFLOW_DESIRED}" && "${MLFLOW_DEPLOYMENT_AVAILABLE:-0}" -ge "${MLFLOW_DESIRED}" ]]; then
        pass "MLflow Deployment is available (${MLFLOW_DEPLOYMENT_AVAILABLE}/${MLFLOW_DESIRED})."
    else
        fail "MLflow Deployment is not fully available (${MLFLOW_DEPLOYMENT_AVAILABLE:-0}/${MLFLOW_DESIRED:-unknown})."
    fi
    if [[ "${MLFLOW_URL}" == https://* ]]; then
        pass "MLflow external URL is published: ${MLFLOW_URL}"
    else
        fail "MLflow external URL is missing or invalid: ${MLFLOW_URL:-unavailable}"
    fi

    MLFLOW_ROLE_REF="$(oc get rolebinding "${MLFLOW_ROLE_BINDING}" -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{.roleRef.kind}:{.roleRef.name}' 2>/dev/null || true)"
    MLFLOW_ROLE_SUBJECTS="$(oc get rolebinding "${MLFLOW_ROLE_BINDING}" -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{range .subjects[*]}{.kind}:{.namespace}:{.name}{"\n"}{end}' 2>/dev/null || true)"
    if [[ "${MLFLOW_ROLE_REF}" == "ClusterRole:${MLFLOW_INTEGRATION_CLUSTER_ROLE}" ]] \
        && grep -Fxq "ServiceAccount:${ZENML_WORKLOAD_NAMESPACE}:${ZENML_ORCHESTRATOR_SA}" <<< "${MLFLOW_ROLE_SUBJECTS}"; then
        pass "MLflow integration RoleBinding targets the orchestrator service account."
    else
        fail "MLflow integration RoleBinding is missing or incorrectly configured: ${MLFLOW_ROLE_BINDING}"
    fi
fi

if [[ "${CURL_AVAILABLE}" == true && -n "${MLFLOW_URL}" ]]; then
    MLFLOW_HTTP_STATUS="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 15 "${MLFLOW_URL}" || true)"
    if [[ "${MLFLOW_HTTP_STATUS}" == 200 || "${MLFLOW_HTTP_STATUS}" == 302 || "${MLFLOW_HTTP_STATUS}" == 401 || "${MLFLOW_HTTP_STATUS}" == 403 ]]; then
        pass "MLflow external endpoint is reachable (HTTP ${MLFLOW_HTTP_STATUS})."
    else
        fail "MLflow external endpoint returned HTTP ${MLFLOW_HTTP_STATUS:-unavailable}."
    fi
else
    skip "MLflow HTTP reachability requires curl and a published URL."
fi

section "Checking MinIO and artifact storage"
MINIO_ENDPOINT=""
if [[ "${PROJECT_EXISTS}" != true ]]; then
    skip "MinIO checks require the workload project."
else
    MINIO_DESIRED="$(oc get deployment minio -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
    MINIO_AVAILABLE="$(oc get deployment minio -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
    if [[ -n "${MINIO_DESIRED}" && "${MINIO_AVAILABLE:-0}" -ge "${MINIO_DESIRED}" ]]; then
        pass "MinIO Deployment is available (${MINIO_AVAILABLE}/${MINIO_DESIRED})."
    else
        fail "MinIO Deployment is not fully available (${MINIO_AVAILABLE:-0}/${MINIO_DESIRED:-unknown})."
    fi

    PVC_PHASE="$(oc get pvc minio-data -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "${PVC_PHASE}" == Bound ]]; then
        pass "MinIO PersistentVolumeClaim is bound."
    else
        fail "MinIO PersistentVolumeClaim status is ${PVC_PHASE:-missing}; expected Bound."
    fi

    MINIO_ENDPOINTS="$(oc get endpoints minio -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{" "}{end}' 2>/dev/null || true)"
    if [[ -n "${MINIO_ENDPOINTS}" ]]; then
        pass "MinIO Service has ready endpoints: ${MINIO_ENDPOINTS}"
    else
        fail "MinIO Service has no ready endpoints."
    fi

    MINIO_ROUTE_HOST="$(oc get route "${MINIO_ROUTE_NAME}" -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    MINIO_ROUTE_ADMITTED="$(oc get route "${MINIO_ROUTE_NAME}" -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}' 2>/dev/null || true)"
    if [[ -n "${MINIO_ROUTE_HOST}" && "${MINIO_ROUTE_ADMITTED}" == True ]]; then
        MINIO_ENDPOINT="https://${MINIO_ROUTE_HOST}"
        pass "MinIO Route is admitted: ${MINIO_ENDPOINT}"
    else
        fail "MinIO Route is missing or not admitted."
    fi

    BUCKET_JOB_COMPLETE="$(oc get job minio-bootstrap -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
    if [[ "${BUCKET_JOB_COMPLETE}" == True ]]; then
        pass "MinIO bucket bootstrap and smoke-test Job completed."
    else
        fail "MinIO bucket bootstrap Job is missing or incomplete."
    fi
fi

if [[ "${CURL_AVAILABLE}" == true && -n "${MINIO_ENDPOINT}" ]]; then
    if curl --fail --silent --show-error --max-time 15 "${MINIO_ENDPOINT}/minio/health/ready" >/dev/null; then
        pass "MinIO public health endpoint responded successfully."
    else
        fail "MinIO public health endpoint failed: ${MINIO_ENDPOINT}"
    fi
else
    skip "MinIO HTTP health requires curl and an admitted Route."
fi

section "Checking the OpenShift image registry"
REGISTRY_HOST=""
if [[ "${OC_AVAILABLE}" != true ]]; then
    skip "Registry checks require an authenticated oc CLI."
else
    REGISTRY_STATE="$(oc get configs.imageregistry.operator.openshift.io cluster -o jsonpath='{.spec.managementState}' 2>/dev/null || true)"
    REGISTRY_DEFAULT_ROUTE="$(oc get configs.imageregistry.operator.openshift.io cluster -o jsonpath='{.spec.defaultRoute}' 2>/dev/null || true)"
    if [[ "${REGISTRY_STATE}" == Managed ]]; then
        pass "OpenShift image registry is Managed."
    else
        fail "OpenShift image registry state is ${REGISTRY_STATE:-unavailable}; expected Managed."
    fi
    if [[ "${REGISTRY_DEFAULT_ROUTE}" == true ]]; then
        pass "OpenShift registry default Route is enabled."
    else
        fail "OpenShift registry default Route is not enabled."
    fi

    REGISTRY_HOST="$(oc get route "${OPENSHIFT_REGISTRY_ROUTE}" -n "${OPENSHIFT_REGISTRY_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    REGISTRY_ROUTE_ADMITTED="$(oc get route "${OPENSHIFT_REGISTRY_ROUTE}" -n "${OPENSHIFT_REGISTRY_NAMESPACE}" -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}' 2>/dev/null || true)"
    if [[ -n "${REGISTRY_HOST}" && "${REGISTRY_ROUTE_ADMITTED}" == True ]]; then
        pass "OpenShift registry Route is admitted: ${REGISTRY_HOST}"
    else
        fail "OpenShift registry Route is missing or not admitted."
    fi

    if oc get imagestream zenml -n "${ZENML_WORKLOAD_NAMESPACE}" >/dev/null 2>&1; then
        pass "ZenML ImageStream exists in the workload project."
    else
        fail "ZenML ImageStream was not found in the workload project."
    fi
fi

if [[ "${CURL_AVAILABLE}" == true && -n "${REGISTRY_HOST}" ]]; then
    REGISTRY_HTTP_STATUS="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 15 "https://${REGISTRY_HOST}/v2/" || true)"
    if [[ "${REGISTRY_HTTP_STATUS}" == 200 || "${REGISTRY_HTTP_STATUS}" == 401 ]]; then
        pass "Registry v2 endpoint is reachable (HTTP ${REGISTRY_HTTP_STATUS})."
    else
        fail "Registry v2 endpoint returned HTTP ${REGISTRY_HTTP_STATUS:-unavailable}."
    fi
else
    skip "Registry HTTP health requires curl and an admitted Route."
fi

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

section "Workload-stack validation summary"
if [[ "${FAILURES}" -eq 0 ]]; then
    success "All workload-stack checks passed."
    exit 0
fi

echo "    ${FAILURES} validation check(s) failed." >&2
echo "    Reconcile the stack with: just bootstrap-stack" >&2
exit 1
