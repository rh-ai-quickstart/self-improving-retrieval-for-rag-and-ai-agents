#!/usr/bin/env bash

zenml_public_secret_id() {
    local secret_name="$1"

    "${ZENML_PYTHON:-python}" - "${secret_name}" <<'PY'
import contextlib
import sys

# ZenML can print global-version warnings to stdout while importing or loading
# its client. Keep stdout machine-readable because callers capture this UUID.
with contextlib.redirect_stdout(sys.stderr):
    from zenml.client import Client

try:
    with contextlib.redirect_stdout(sys.stderr):
        secret = Client().get_secret_by_name_and_private_status(
            name=sys.argv[1],
            private=False,
            hydrate=False,
        )
except KeyError:
    raise SystemExit(1)

print(secret.id)
PY
}

load_stack_config() {
    local config_file="$1"

    [[ -f "${config_file}" ]] || die "Configuration file not found: ${config_file}. Copy deployment.env.example to deployment.env and edit it first."
    info "Environment file: ${config_file}"
    info "The environment file is trusted input and is loaded as shell configuration."

    # shellcheck disable=SC1090
    source "${config_file}"

    ZENML_PYTHON="${ZENML_PYTHON:-python}"
    zenml_resolve_version
    ZENML_WORKLOAD_NAMESPACE="${ZENML_WORKLOAD_NAMESPACE:-zenml-workloads}"
    ZENML_ORCHESTRATOR_SA="${ZENML_ORCHESTRATOR_SA:-zenml-orchestrator}"
    ZENML_REGISTRY_PULL_SECRET="${ZENML_REGISTRY_PULL_SECRET:-openshift-registry-route-pull}"
    ZENML_K8S_CONNECTOR="${ZENML_K8S_CONNECTOR:-openshift-k8s}"
    ZENML_K8S_CLUSTER_NAME="${ZENML_K8S_CLUSTER_NAME:-}"
    ZENML_K8S_TOKEN_DURATION="${ZENML_K8S_TOKEN_DURATION:-24h}"
    ZENML_CREDENTIAL_EXPIRY_SKEW_SECONDS="${ZENML_CREDENTIAL_EXPIRY_SKEW_SECONDS:-300}"
    ZENML_ORCHESTRATOR="${ZENML_ORCHESTRATOR:-openshift-k8s}"
    ZENML_ARTIFACT_STORE="${ZENML_ARTIFACT_STORE:-openshift-s4}"
    ZENML_ARTIFACT_SECRET="${ZENML_ARTIFACT_SECRET:-s4-artifact-store}"
    ZENML_CONTAINER_REGISTRY="${ZENML_CONTAINER_REGISTRY:-openshift-internal}"
    ZENML_IMAGE_BUILDER="${ZENML_IMAGE_BUILDER:-openshift-local}"
    ZENML_EXPERIMENT_TRACKER="${ZENML_EXPERIMENT_TRACKER:-openshift-mlflow}"
    ZENML_MLFLOW_TOKEN_DURATION="${ZENML_MLFLOW_TOKEN_DURATION:-24h}"
    ZENML_STACK="${ZENML_STACK:-openshift}"
    ZENML_DELETE_FALLBACK_STACK="${ZENML_DELETE_FALLBACK_STACK:-default}"

    S4_IMAGE_REPOSITORY="${S4_IMAGE_REPOSITORY:-quay.io/rh-aiservices-bu/s4}"
    S4_IMAGE_TAG="${S4_IMAGE_TAG:-0.3.2}"
    S4_SECRET_NAME="${S4_SECRET_NAME:-s4-credentials}"
    S4_ACCESS_KEY_ID="${S4_ACCESS_KEY_ID:-s4admin}"
    S4_SECRET_ACCESS_KEY="${S4_SECRET_ACCESS_KEY:-}"
    S4_UI_AUTH_USERNAME="${S4_UI_AUTH_USERNAME:-admin}"
    S4_UI_AUTH_PASSWORD="${S4_UI_AUTH_PASSWORD:-}"
    S4_STORAGE_CLASS="${S4_STORAGE_CLASS:-gp3-csi}"
    S4_STORAGE_SIZE="${S4_STORAGE_SIZE:-10Gi}"
    S4_BUCKET="${S4_BUCKET:-zenml-artifacts}"
    S4_UI_ROUTE_NAME="${S4_UI_ROUTE_NAME:-s4}"
    S4_API_ROUTE_NAME="${S4_API_ROUTE_NAME:-s4-api}"
    S4_INCLUSTER_ENDPOINT="${S4_INCLUSTER_ENDPOINT:-http://s4:7480}"
    S4_CLIENT_IMAGE="${S4_CLIENT_IMAGE:-registry.redhat.io/ubi9/python-311:latest}"
    JOB_IMAGE_CLI="${JOB_IMAGE_CLI:-image-registry.openshift-image-registry.svc:5000/openshift/cli:latest}"
    JOB_IMAGE_PYTHON="${JOB_IMAGE_PYTHON:-registry.redhat.io/ubi9/python-311:latest}"

    OPENSHIFT_AI_DSC="${OPENSHIFT_AI_DSC:-default-dsc}"
    OPENSHIFT_AI_APPLICATIONS_NAMESPACE="${OPENSHIFT_AI_APPLICATIONS_NAMESPACE:-redhat-ods-applications}"
    MLFLOW_INSTANCE="${MLFLOW_INSTANCE:-mlflow}"
    MLFLOW_STORAGE_CLASS="${MLFLOW_STORAGE_CLASS:-gp3-csi}"
    MLFLOW_STORAGE_SIZE="${MLFLOW_STORAGE_SIZE:-10Gi}"
    MLFLOW_INTEGRATION_CLUSTER_ROLE="${MLFLOW_INTEGRATION_CLUSTER_ROLE:-mlflow-operator-mlflow-integration}"
    MLFLOW_ROLE_BINDING="${MLFLOW_ROLE_BINDING:-zenml-mlflow-integration}"
    MODEL_SERVING_NAME="${MODEL_SERVING_NAME:-retrieval-embedding}"
    MODEL_SERVING_ROUTE="${MODEL_SERVING_ROUTE:-${MODEL_SERVING_NAME}-ui}"
    MODEL_SERVING_ROLE="${MODEL_SERVING_ROLE:-zenml-kserve-deployer}"
    MODEL_SERVING_ROLE_BINDING="${MODEL_SERVING_ROLE_BINDING:-zenml-kserve-deployer}"
    MODEL_SERVING_TIMEOUT="${MODEL_SERVING_TIMEOUT:-600}"

    OPENSHIFT_REGISTRY_NAMESPACE="${OPENSHIFT_REGISTRY_NAMESPACE:-openshift-image-registry}"
    OPENSHIFT_REGISTRY_ROUTE="${OPENSHIFT_REGISTRY_ROUTE:-default-route}"
    OPENSHIFT_REGISTRY_USERNAME="${OPENSHIFT_REGISTRY_USERNAME:-openshift}"
    ZENML_REGISTRY_TOKEN_DURATION="${ZENML_REGISTRY_TOKEN_DURATION:-24h}"
    ZENML_STACK_DELETE_CONFIRM="${ZENML_STACK_DELETE_CONFIRM:-}"

    validate_dns_name "ZENML_WORKLOAD_NAMESPACE" "${ZENML_WORKLOAD_NAMESPACE}"
    validate_dns_name "ZENML_ORCHESTRATOR_SA" "${ZENML_ORCHESTRATOR_SA}"
    validate_dns_name "ZENML_REGISTRY_PULL_SECRET" "${ZENML_REGISTRY_PULL_SECRET}"
    validate_dns_name "S4_SECRET_NAME" "${S4_SECRET_NAME}"
    validate_dns_name "S4_BUCKET" "${S4_BUCKET}"
    validate_dns_name "S4_UI_ROUTE_NAME" "${S4_UI_ROUTE_NAME}"
    validate_dns_name "S4_API_ROUTE_NAME" "${S4_API_ROUTE_NAME}"
    validate_dns_name "OPENSHIFT_AI_DSC" "${OPENSHIFT_AI_DSC}"
    validate_dns_name "OPENSHIFT_AI_APPLICATIONS_NAMESPACE" "${OPENSHIFT_AI_APPLICATIONS_NAMESPACE}"
    validate_dns_name "MLFLOW_INSTANCE" "${MLFLOW_INSTANCE}"
    validate_dns_name "MLFLOW_ROLE_BINDING" "${MLFLOW_ROLE_BINDING}"
    validate_dns_name "MODEL_SERVING_NAME" "${MODEL_SERVING_NAME}"
    validate_dns_name "MODEL_SERVING_ROUTE" "${MODEL_SERVING_ROUTE}"
    validate_dns_name "MODEL_SERVING_ROLE" "${MODEL_SERVING_ROLE}"
    validate_dns_name "MODEL_SERVING_ROLE_BINDING" "${MODEL_SERVING_ROLE_BINDING}"

    if [[ ! "${MODEL_SERVING_TIMEOUT}" =~ ^[1-9][0-9]*$ ]]; then
        die "MODEL_SERVING_TIMEOUT must be a positive number of seconds: ${MODEL_SERVING_TIMEOUT}"
    fi
    if [[ ! "${ZENML_CREDENTIAL_EXPIRY_SKEW_SECONDS}" =~ ^[0-9]+$ ]]; then
        die "ZENML_CREDENTIAL_EXPIRY_SKEW_SECONDS must be a non-negative number of seconds: ${ZENML_CREDENTIAL_EXPIRY_SKEW_SECONDS}"
    fi

    if [[ "${ZENML_WORKLOAD_NAMESPACE}" == "${ZENML_NAMESPACE:-zenml}" ]]; then
        die "ZENML_WORKLOAD_NAMESPACE must differ from the ZenML server project (${ZENML_NAMESPACE:-zenml})."
    fi
    if [[ "${ZENML_DELETE_FALLBACK_STACK}" == "${ZENML_STACK}" ]]; then
        die "ZENML_DELETE_FALLBACK_STACK must differ from ZENML_STACK."
    fi
}
