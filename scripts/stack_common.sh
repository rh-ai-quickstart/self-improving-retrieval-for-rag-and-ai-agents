#!/usr/bin/env bash

# Shared configuration and output helpers for the ZenML workload-stack scripts.

STACK_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STACK_REPO_ROOT="$(cd -- "${STACK_SCRIPT_DIR}/.." && pwd)"

section() {
    echo
    echo "======================================================================"
    echo "==> $1"
    echo "======================================================================"
}

info() {
    echo "    $1"
}

success() {
    echo "    OK: $1"
}

warn() {
    echo "    WARNING: $1" >&2
}

die() {
    echo >&2
    echo "ERROR: $1" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

zenml_public_secret_id() {
    local secret_name="$1"

    "${ZENML_PYTHON:-python}" - "${secret_name}" <<'PY'
import sys

from zenml.client import Client

try:
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

validate_dns_name() {
    local label="$1"
    local value="$2"

    if [[ ! "${value}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
        die "${label} must be a lowercase DNS label: ${value}"
    fi
}

load_stack_config() {
    local config_file="$1"

    [[ -f "${config_file}" ]] || die "Configuration file not found: ${config_file}. Copy deployment.env.example to deployment.env and edit it first."
    info "Environment file: ${config_file}"
    info "The environment file is trusted input and is loaded as shell configuration."

    # shellcheck disable=SC1090
    source "${config_file}"

    ZENML_VERSION="${ZENML_VERSION:-0.96.2}"
    ZENML_WORKLOAD_NAMESPACE="${ZENML_WORKLOAD_NAMESPACE:-zenml-workloads}"
    ZENML_ORCHESTRATOR_SA="${ZENML_ORCHESTRATOR_SA:-zenml-orchestrator}"
    ZENML_REGISTRY_PULL_SECRET="${ZENML_REGISTRY_PULL_SECRET:-openshift-registry-route-pull}"
    ZENML_K8S_CONNECTOR="${ZENML_K8S_CONNECTOR:-openshift-k8s}"
    ZENML_K8S_CLUSTER_NAME="${ZENML_K8S_CLUSTER_NAME:-}"
    ZENML_K8S_TOKEN_DURATION="${ZENML_K8S_TOKEN_DURATION:-24h}"
    ZENML_ORCHESTRATOR="${ZENML_ORCHESTRATOR:-openshift-k8s}"
    ZENML_ARTIFACT_STORE="${ZENML_ARTIFACT_STORE:-openshift-minio}"
    ZENML_ARTIFACT_SECRET="${ZENML_ARTIFACT_SECRET:-minio-artifact-store}"
    ZENML_CONTAINER_REGISTRY="${ZENML_CONTAINER_REGISTRY:-openshift-internal}"
    ZENML_IMAGE_BUILDER="${ZENML_IMAGE_BUILDER:-openshift-local}"
    ZENML_EXPERIMENT_TRACKER="${ZENML_EXPERIMENT_TRACKER:-openshift-mlflow}"
    ZENML_MLFLOW_TOKEN_DURATION="${ZENML_MLFLOW_TOKEN_DURATION:-24h}"
    ZENML_STACK="${ZENML_STACK:-openshift}"
    ZENML_DELETE_FALLBACK_STACK="${ZENML_DELETE_FALLBACK_STACK:-default}"
    ZENML_PYTHON="${ZENML_PYTHON:-python}"

    MINIO_IMAGE="${MINIO_IMAGE:-quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z}"
    MINIO_CLIENT_IMAGE="${MINIO_CLIENT_IMAGE:-quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z}"
    MINIO_SECRET_NAME="${MINIO_SECRET_NAME:-minio-root}"
    MINIO_ROOT_USER="${MINIO_ROOT_USER:-zenml-admin}"
    MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-}"
    MINIO_STORAGE_CLASS="${MINIO_STORAGE_CLASS:-gp3-csi}"
    MINIO_STORAGE_SIZE="${MINIO_STORAGE_SIZE:-10Gi}"
    MINIO_BUCKET="${MINIO_BUCKET:-zenml-artifacts}"
    MINIO_ROUTE_NAME="${MINIO_ROUTE_NAME:-minio-s3}"

    OPENSHIFT_AI_DSC="${OPENSHIFT_AI_DSC:-default-dsc}"
    OPENSHIFT_AI_APPLICATIONS_NAMESPACE="${OPENSHIFT_AI_APPLICATIONS_NAMESPACE:-redhat-ods-applications}"
    MLFLOW_INSTANCE="${MLFLOW_INSTANCE:-mlflow}"
    MLFLOW_STORAGE_CLASS="${MLFLOW_STORAGE_CLASS:-gp3-csi}"
    MLFLOW_STORAGE_SIZE="${MLFLOW_STORAGE_SIZE:-10Gi}"
    MLFLOW_INTEGRATION_CLUSTER_ROLE="${MLFLOW_INTEGRATION_CLUSTER_ROLE:-mlflow-operator-mlflow-integration}"
    MLFLOW_ROLE_BINDING="${MLFLOW_ROLE_BINDING:-zenml-mlflow-integration}"

    OPENSHIFT_REGISTRY_NAMESPACE="${OPENSHIFT_REGISTRY_NAMESPACE:-openshift-image-registry}"
    OPENSHIFT_REGISTRY_ROUTE="${OPENSHIFT_REGISTRY_ROUTE:-default-route}"
    OPENSHIFT_REGISTRY_USERNAME="${OPENSHIFT_REGISTRY_USERNAME:-openshift}"
    ZENML_REGISTRY_TOKEN_DURATION="${ZENML_REGISTRY_TOKEN_DURATION:-24h}"
    ZENML_STACK_DELETE_CONFIRM="${ZENML_STACK_DELETE_CONFIRM:-}"

    validate_dns_name "ZENML_WORKLOAD_NAMESPACE" "${ZENML_WORKLOAD_NAMESPACE}"
    validate_dns_name "ZENML_ORCHESTRATOR_SA" "${ZENML_ORCHESTRATOR_SA}"
    validate_dns_name "ZENML_REGISTRY_PULL_SECRET" "${ZENML_REGISTRY_PULL_SECRET}"
    validate_dns_name "MINIO_SECRET_NAME" "${MINIO_SECRET_NAME}"
    validate_dns_name "MINIO_BUCKET" "${MINIO_BUCKET}"
    validate_dns_name "MINIO_ROUTE_NAME" "${MINIO_ROUTE_NAME}"
    validate_dns_name "OPENSHIFT_AI_DSC" "${OPENSHIFT_AI_DSC}"
    validate_dns_name "OPENSHIFT_AI_APPLICATIONS_NAMESPACE" "${OPENSHIFT_AI_APPLICATIONS_NAMESPACE}"
    validate_dns_name "MLFLOW_INSTANCE" "${MLFLOW_INSTANCE}"
    validate_dns_name "MLFLOW_ROLE_BINDING" "${MLFLOW_ROLE_BINDING}"

    if [[ "${ZENML_WORKLOAD_NAMESPACE}" == "${ZENML_NAMESPACE:-zenml}" ]]; then
        die "ZENML_WORKLOAD_NAMESPACE must differ from the ZenML server project (${ZENML_NAMESPACE:-zenml})."
    fi
    if [[ "${ZENML_DELETE_FALLBACK_STACK}" == "${ZENML_STACK}" ]]; then
        die "ZENML_DELETE_FALLBACK_STACK must differ from ZENML_STACK."
    fi
}
