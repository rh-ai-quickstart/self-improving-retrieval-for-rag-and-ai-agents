#!/usr/bin/env bash
set -euo pipefail

# Provision the OpenShift resources and ZenML components for remote pipelines.
# The ZenML server must already be activated and the local CLI logged in.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${1:-${REPO_ROOT}/deployment.env}"
RESOURCE_TEMPLATE="${REPO_ROOT}/openshift/zenml-stack-resources.yaml"
BUCKET_JOB_TEMPLATE="${REPO_ROOT}/openshift/minio-bootstrap-job.yaml"
MLFLOW_TEMPLATE="${REPO_ROOT}/openshift/mlflow.yaml"

# shellcheck source=stack_common.sh
source "${SCRIPT_DIR}/stack_common.sh"

cleanup_files=()
cleanup() {
    local path
    for path in "${cleanup_files[@]:-}"; do
        [[ -z "${path}" ]] && continue
        if [[ -d "${path}" ]]; then
            rm -f -- "${path}/MINIO_ROOT_USER" "${path}/MINIO_ROOT_PASSWORD"
            rmdir -- "${path}" 2>/dev/null || true
        else
            rm -f -- "${path}"
        fi
    done
}
trap cleanup EXIT

component_exists() {
    local component_command="$1"
    local component_name="$2"
    zenml "${component_command}" describe "${component_name}" >/dev/null 2>&1
}

section "Loading workload-stack configuration"
load_stack_config "${CONFIG_FILE}"
[[ -f "${RESOURCE_TEMPLATE}" ]] || die "OpenShift template not found: ${RESOURCE_TEMPLATE}"
[[ -f "${BUCKET_JOB_TEMPLATE}" ]] || die "OpenShift template not found: ${BUCKET_JOB_TEMPLATE}"
[[ -f "${MLFLOW_TEMPLATE}" ]] || die "OpenShift template not found: ${MLFLOW_TEMPLATE}"

info "Workload project:    ${ZENML_WORKLOAD_NAMESPACE}"
info "Orchestrator SA:     ${ZENML_ORCHESTRATOR_SA}"
info "ZenML stack:         ${ZENML_STACK}"
info "MinIO image:         ${MINIO_IMAGE}"
info "MinIO client image:  ${MINIO_CLIENT_IMAGE}"
info "MinIO storage:       ${MINIO_STORAGE_CLASS}/${MINIO_STORAGE_SIZE}"
info "MinIO bucket:        ${MINIO_BUCKET}"
info "MLflow instance:     ${MLFLOW_INSTANCE}"
info "Experiment tracker:  ${ZENML_EXPERIMENT_TRACKER}"

section "Checking local clients and authenticated services"
require_command oc
require_command curl
require_command docker
require_command zenml
require_command openssl
require_command python3
require_command "${ZENML_PYTHON}"

oc whoami >/dev/null 2>&1 || die "The oc CLI is not authenticated to OpenShift."
zenml status >/dev/null 2>&1 || die "The ZenML CLI is not authenticated to the deployed server."
docker info >/dev/null 2>&1 || die "The local Docker daemon is not reachable."

CLIENT_VERSION="$("${ZENML_PYTHON}" -c 'import zenml; print(zenml.__version__)')"
[[ "${CLIENT_VERSION}" == "${ZENML_VERSION}" ]] || die "ZenML Python client ${CLIENT_VERSION} does not match configured server version ${ZENML_VERSION}."
"${ZENML_PYTHON}" -c 'import docker; assert docker.from_env().ping()' >/dev/null \
    || die "The ZenML Python environment cannot reach Docker through the Docker SDK."
"${ZENML_PYTHON}" - <<'PY' >/dev/null \
    || die "The ZenML Python environment requires MLflow >=3.11,<4. Install it with: python -m pip install 'mlflow[kubernetes]>=3.11,<4'"
from packaging.version import Version
import mlflow

version = Version(mlflow.__version__)
assert Version("3.11") <= version < Version("4")
PY

OPENSHIFT_USER="$(oc whoami)"
OPENSHIFT_SERVER="$(oc whoami --show-server)"
success "Authenticated to OpenShift as ${OPENSHIFT_USER}"
success "ZenML client/server version is ${ZENML_VERSION}"
success "Docker CLI and Python SDK can reach the daemon"

section "Creating the dedicated workload project and identity"
if oc get project "${ZENML_WORKLOAD_NAMESPACE}" >/dev/null 2>&1; then
    info "Project ${ZENML_WORKLOAD_NAMESPACE} already exists."
else
    oc new-project "${ZENML_WORKLOAD_NAMESPACE}" >/dev/null
    success "Created project ${ZENML_WORKLOAD_NAMESPACE}."
fi

oc create serviceaccount "${ZENML_ORCHESTRATOR_SA}" \
    -n "${ZENML_WORKLOAD_NAMESPACE}" \
    --dry-run=client \
    -o yaml \
    | oc apply -f - >/dev/null
oc label serviceaccount "${ZENML_ORCHESTRATOR_SA}" \
    -n "${ZENML_WORKLOAD_NAMESPACE}" \
    app.kubernetes.io/part-of=zenml-stack-bootstrap \
    --overwrite >/dev/null

oc adm policy add-role-to-user edit \
    -z "${ZENML_ORCHESTRATOR_SA}" \
    -n "${ZENML_WORKLOAD_NAMESPACE}" >/dev/null
oc adm policy add-role-to-user system:image-puller \
    -z "${ZENML_ORCHESTRATOR_SA}" \
    -n "${ZENML_WORKLOAD_NAMESPACE}" >/dev/null
oc adm policy add-role-to-user system:image-builder \
    -z "${ZENML_ORCHESTRATOR_SA}" \
    -n "${ZENML_WORKLOAD_NAMESPACE}" >/dev/null

[[ "$(oc auth can-i create pods --as="system:serviceaccount:${ZENML_WORKLOAD_NAMESPACE}:${ZENML_ORCHESTRATOR_SA}" -n "${ZENML_WORKLOAD_NAMESPACE}")" == "yes" ]] \
    || die "${ZENML_ORCHESTRATOR_SA} cannot create pods in ${ZENML_WORKLOAD_NAMESPACE}."
[[ "$(oc auth can-i create jobs --as="system:serviceaccount:${ZENML_WORKLOAD_NAMESPACE}:${ZENML_ORCHESTRATOR_SA}" -n "${ZENML_WORKLOAD_NAMESPACE}")" == "yes" ]] \
    || die "${ZENML_ORCHESTRATOR_SA} cannot create jobs in ${ZENML_WORKLOAD_NAMESPACE}."
[[ "$(oc auth can-i update imagestreams/layers --as="system:serviceaccount:${ZENML_WORKLOAD_NAMESPACE}:${ZENML_ORCHESTRATOR_SA}" -n "${ZENML_WORKLOAD_NAMESPACE}")" == "yes" ]] \
    || die "${ZENML_ORCHESTRATOR_SA} cannot push images in ${ZENML_WORKLOAD_NAMESPACE}."
success "Orchestrator service account can create workloads and push project images."

section "Provisioning the shared OpenShift AI MLflow instance"
MLFLOW_OPERATOR_STATE="$(oc get datasciencecluster "${OPENSHIFT_AI_DSC}" \
    -o jsonpath='{.spec.components.mlflowoperator.managementState}' 2>/dev/null || true)"
[[ "${MLFLOW_OPERATOR_STATE}" == "Managed" ]] \
    || die "OpenShift AI MLflow operator is ${MLFLOW_OPERATOR_STATE:-unavailable}; expected Managed on DataScienceCluster ${OPENSHIFT_AI_DSC}."
oc get crd mlflows.mlflow.opendatahub.io >/dev/null 2>&1 \
    || die "OpenShift AI MLflow CRD mlflows.mlflow.opendatahub.io is not installed."
oc get clusterrole "${MLFLOW_INTEGRATION_CLUSTER_ROLE}" >/dev/null 2>&1 \
    || die "OpenShift AI MLflow integration ClusterRole not found: ${MLFLOW_INTEGRATION_CLUSTER_ROLE}"

if oc get mlflow "${MLFLOW_INSTANCE}" >/dev/null 2>&1; then
    info "Preserving existing cluster-scoped MLflow instance ${MLFLOW_INSTANCE}."
else
    oc get storageclass "${MLFLOW_STORAGE_CLASS}" >/dev/null 2>&1 \
        || die "StorageClass not found for MLflow: ${MLFLOW_STORAGE_CLASS}"
    oc process -f "${MLFLOW_TEMPLATE}" \
        -p "MLFLOW_INSTANCE=${MLFLOW_INSTANCE}" \
        -p "MLFLOW_STORAGE_CLASS=${MLFLOW_STORAGE_CLASS}" \
        -p "MLFLOW_STORAGE_SIZE=${MLFLOW_STORAGE_SIZE}" \
        | oc apply -f - >/dev/null
    success "Created cluster-scoped MLflow instance ${MLFLOW_INSTANCE}."
fi

oc wait --for=condition=Available "mlflow/${MLFLOW_INSTANCE}" --timeout=300s
oc rollout status "deployment/${MLFLOW_INSTANCE}" \
    -n "${OPENSHIFT_AI_APPLICATIONS_NAMESPACE}" \
    --timeout=180s
MLFLOW_URL="$(oc get mlflow "${MLFLOW_INSTANCE}" -o jsonpath='{.status.url}')"
[[ "${MLFLOW_URL}" == https://* ]] \
    || die "MLflow external URL is missing or invalid: ${MLFLOW_URL:-unavailable}"

oc create rolebinding "${MLFLOW_ROLE_BINDING}" \
    --clusterrole="${MLFLOW_INTEGRATION_CLUSTER_ROLE}" \
    --serviceaccount="${ZENML_WORKLOAD_NAMESPACE}:${ZENML_ORCHESTRATOR_SA}" \
    -n "${ZENML_WORKLOAD_NAMESPACE}" \
    --dry-run=client \
    -o yaml \
    | oc apply -f - >/dev/null
success "MLflow is available at ${MLFLOW_URL}; workload integration RBAC is configured."

section "Provisioning persistent MinIO"
oc get storageclass "${MINIO_STORAGE_CLASS}" >/dev/null 2>&1 \
    || die "StorageClass not found: ${MINIO_STORAGE_CLASS}"

if oc get secret "${MINIO_SECRET_NAME}" -n "${ZENML_WORKLOAD_NAMESPACE}" >/dev/null 2>&1; then
    info "Preserving existing MinIO credentials in Secret ${MINIO_SECRET_NAME}."
else
    MINIO_CREDENTIAL_DIR="$(mktemp -d)"
    cleanup_files+=("${MINIO_CREDENTIAL_DIR}")
    chmod 700 "${MINIO_CREDENTIAL_DIR}"
    if [[ -z "${MINIO_ROOT_PASSWORD}" ]]; then
        MINIO_ROOT_PASSWORD="$(openssl rand -hex 24)"
        info "Generated a random MinIO root password."
    fi
    printf '%s' "${MINIO_ROOT_USER}" > "${MINIO_CREDENTIAL_DIR}/MINIO_ROOT_USER"
    printf '%s' "${MINIO_ROOT_PASSWORD}" > "${MINIO_CREDENTIAL_DIR}/MINIO_ROOT_PASSWORD"
    chmod 600 "${MINIO_CREDENTIAL_DIR}"/*
    oc create secret generic "${MINIO_SECRET_NAME}" \
        -n "${ZENML_WORKLOAD_NAMESPACE}" \
        --from-file="MINIO_ROOT_USER=${MINIO_CREDENTIAL_DIR}/MINIO_ROOT_USER" \
        --from-file="MINIO_ROOT_PASSWORD=${MINIO_CREDENTIAL_DIR}/MINIO_ROOT_PASSWORD" \
        --dry-run=client \
        -o yaml \
        | oc apply -f - >/dev/null
fi
oc label secret "${MINIO_SECRET_NAME}" \
    -n "${ZENML_WORKLOAD_NAMESPACE}" \
    app.kubernetes.io/part-of=zenml-stack-bootstrap \
    --overwrite >/dev/null

oc process -f "${RESOURCE_TEMPLATE}" \
    -p "MINIO_IMAGE=${MINIO_IMAGE}" \
    -p "MINIO_SECRET_NAME=${MINIO_SECRET_NAME}" \
    -p "MINIO_STORAGE_CLASS=${MINIO_STORAGE_CLASS}" \
    -p "MINIO_STORAGE_SIZE=${MINIO_STORAGE_SIZE}" \
    -p "MINIO_ROUTE_NAME=${MINIO_ROUTE_NAME}" \
    | oc apply -n "${ZENML_WORKLOAD_NAMESPACE}" -f - >/dev/null

oc rollout status deployment/minio \
    -n "${ZENML_WORKLOAD_NAMESPACE}" \
    --timeout=180s
MINIO_ROUTE_HOST="$(oc get route "${MINIO_ROUTE_NAME}" -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{.spec.host}')"
MINIO_ENDPOINT="https://${MINIO_ROUTE_HOST}"
curl --fail --silent --show-error --max-time 15 \
    "${MINIO_ENDPOINT}/minio/health/ready" >/dev/null \
    || die "MinIO Route health check failed: ${MINIO_ENDPOINT}"
success "MinIO is healthy at ${MINIO_ENDPOINT}."

section "Creating and smoke-testing the artifact bucket"
MINIO_JOB_COMPLETE="$(oc get job minio-bootstrap \
    -n "${ZENML_WORKLOAD_NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
if [[ "${MINIO_JOB_COMPLETE}" == "True" ]]; then
    success "MinIO bootstrap Job already completed."
else
    oc delete job minio-bootstrap \
        -n "${ZENML_WORKLOAD_NAMESPACE}" \
        --ignore-not-found >/dev/null
    oc process -f "${BUCKET_JOB_TEMPLATE}" \
        -p "MINIO_CLIENT_IMAGE=${MINIO_CLIENT_IMAGE}" \
        -p "MINIO_SECRET_NAME=${MINIO_SECRET_NAME}" \
        -p "MINIO_BUCKET=${MINIO_BUCKET}" \
        | oc apply -n "${ZENML_WORKLOAD_NAMESPACE}" -f - >/dev/null
    oc wait --for=condition=complete job/minio-bootstrap \
        -n "${ZENML_WORKLOAD_NAMESPACE}" \
        --timeout=120s
fi
oc logs job/minio-bootstrap -n "${ZENML_WORKLOAD_NAMESPACE}" --tail=20
success "Bucket ${MINIO_BUCKET} passed the MinIO write/read smoke test."

section "Exposing and authenticating to the OpenShift image registry"
REGISTRY_STATE="$(oc get configs.imageregistry.operator.openshift.io cluster -o jsonpath='{.spec.managementState}')"
[[ "${REGISTRY_STATE}" == "Managed" ]] || die "OpenShift image registry managementState is ${REGISTRY_STATE}, expected Managed."
oc patch configs.imageregistry.operator.openshift.io/cluster \
    --type=merge \
    --patch '{"spec":{"defaultRoute":true}}' >/dev/null

for attempt in {1..30}; do
    REGISTRY_ROUTE_ADMITTED="$(oc get route "${OPENSHIFT_REGISTRY_ROUTE}" \
        -n "${OPENSHIFT_REGISTRY_NAMESPACE}" \
        -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}' \
        2>/dev/null || true)"
    if [[ "${REGISTRY_ROUTE_ADMITTED}" == "True" ]]; then
        break
    fi
    [[ "${attempt}" -lt 30 ]] || die "OpenShift registry Route was not admitted."
    sleep 2
done
REGISTRY_HOST="$(oc get route "${OPENSHIFT_REGISTRY_ROUTE}" -n "${OPENSHIFT_REGISTRY_NAMESPACE}" -o jsonpath='{.spec.host}')"
REGISTRY_URI="${REGISTRY_HOST}/${ZENML_WORKLOAD_NAMESPACE}"

REGISTRY_TOKEN="$(oc create token "${ZENML_ORCHESTRATOR_SA}" \
    -n "${ZENML_WORKLOAD_NAMESPACE}" \
    --duration="${ZENML_REGISTRY_TOKEN_DURATION}")"
printf '%s' "${REGISTRY_TOKEN}" \
    | docker login "${REGISTRY_HOST}" \
        --username "${OPENSHIFT_REGISTRY_USERNAME}" \
        --password-stdin >/dev/null
success "Docker authenticated to ${REGISTRY_HOST} as ${OPENSHIFT_REGISTRY_USERNAME}."

oc create secret docker-registry "${ZENML_REGISTRY_PULL_SECRET}" \
    -n "${ZENML_WORKLOAD_NAMESPACE}" \
    --docker-server="${REGISTRY_HOST}" \
    --docker-username="${OPENSHIFT_REGISTRY_USERNAME}" \
    --docker-password="${REGISTRY_TOKEN}" \
    --dry-run=client \
    -o yaml \
    | oc apply -f - >/dev/null
unset REGISTRY_TOKEN
oc label secret "${ZENML_REGISTRY_PULL_SECRET}" \
    -n "${ZENML_WORKLOAD_NAMESPACE}" \
    app.kubernetes.io/part-of=zenml-stack-bootstrap \
    --overwrite >/dev/null
oc secrets link "${ZENML_ORCHESTRATOR_SA}" "${ZENML_REGISTRY_PULL_SECRET}" \
    -n "${ZENML_WORKLOAD_NAMESPACE}" \
    --for=pull >/dev/null

oc create imagestream zenml \
    -n "${ZENML_WORKLOAD_NAMESPACE}" \
    --dry-run=client \
    -o yaml \
    | oc apply -f - >/dev/null
oc label imagestream zenml \
    -n "${ZENML_WORKLOAD_NAMESPACE}" \
    app.kubernetes.io/part-of=zenml-stack-bootstrap \
    --overwrite >/dev/null
success "Registry repository and renewable pull credentials are configured."

section "Registering the Kubernetes connector and orchestrator"
K8S_SERVER="${OPENSHIFT_SERVER}"
if [[ -z "${ZENML_K8S_CLUSTER_NAME}" ]]; then
    ZENML_K8S_CLUSTER_NAME="$(oc config view --minify -o jsonpath='{.contexts[0].context.cluster}')"
fi
K8S_CA_DATA="$(oc config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
[[ -n "${K8S_CA_DATA}" ]] || die "The current kubeconfig does not contain certificate-authority-data."
K8S_CA="$(printf '%s' "${K8S_CA_DATA}" | python3 -c '
import base64
import sys
certificate = base64.b64decode(sys.stdin.buffer.read())
print(base64.urlsafe_b64encode(certificate).decode())
')"
K8S_TOKEN="$(oc create token "${ZENML_ORCHESTRATOR_SA}" \
    -n "${ZENML_WORKLOAD_NAMESPACE}" \
    --duration="${ZENML_K8S_TOKEN_DURATION}")"

if zenml service-connector describe "${ZENML_K8S_CONNECTOR}" >/dev/null 2>&1; then
    zenml service-connector update "${ZENML_K8S_CONNECTOR}" \
        --cluster_name="${ZENML_K8S_CLUSTER_NAME}" \
        --token="${K8S_TOKEN}" \
        --server="${K8S_SERVER}" \
        --certificate_authority="${K8S_CA}" >/dev/null
else
    zenml service-connector register "${ZENML_K8S_CONNECTOR}" \
        --type=kubernetes \
        --auth-method=token \
        --cluster_name="${ZENML_K8S_CLUSTER_NAME}" \
        --token="${K8S_TOKEN}" \
        --server="${K8S_SERVER}" \
        --certificate_authority="${K8S_CA}" \
        --resource-type=kubernetes-cluster >/dev/null
fi
unset K8S_TOKEN K8S_CA K8S_CA_DATA
zenml service-connector verify "${ZENML_K8S_CONNECTOR}" >/dev/null
success "Kubernetes service connector is verified."

if component_exists orchestrator "${ZENML_ORCHESTRATOR}"; then
    zenml orchestrator update "${ZENML_ORCHESTRATOR}" \
        --kubernetes_namespace="${ZENML_WORKLOAD_NAMESPACE}" \
        --service_account_name="${ZENML_ORCHESTRATOR_SA}" \
        --step_pod_service_account_name="${ZENML_ORCHESTRATOR_SA}" \
        --skip_owner_references=true >/dev/null
else
    zenml orchestrator register "${ZENML_ORCHESTRATOR}" \
        --flavor=kubernetes \
        --kubernetes_namespace="${ZENML_WORKLOAD_NAMESPACE}" \
        --service_account_name="${ZENML_ORCHESTRATOR_SA}" \
        --step_pod_service_account_name="${ZENML_ORCHESTRATOR_SA}" \
        --skip_owner_references=true \
        --connector="${ZENML_K8S_CONNECTOR}" >/dev/null
fi
success "Kubernetes orchestrator is registered with OpenShift owner-reference compatibility."

section "Registering the artifact store, registry, image builder, and stack"
ZENML_SECRET_FILE="$(mktemp)"
cleanup_files+=("${ZENML_SECRET_FILE}")
chmod 600 "${ZENML_SECRET_FILE}"
oc get secret "${MINIO_SECRET_NAME}" -n "${ZENML_WORKLOAD_NAMESPACE}" -o json \
    | python3 -c '
import base64
import json
import sys
secret = json.load(sys.stdin)["data"]
values = {
    "access_key_id": base64.b64decode(secret["MINIO_ROOT_USER"]).decode(),
    "secret_access_key": base64.b64decode(secret["MINIO_ROOT_PASSWORD"]).decode(),
}
json.dump(values, sys.stdout)
' > "${ZENML_SECRET_FILE}"

if ZENML_ARTIFACT_SECRET_ID="$(zenml_public_secret_id "${ZENML_ARTIFACT_SECRET}" 2>/dev/null)"; then
    zenml secret update "${ZENML_ARTIFACT_SECRET_ID}" --values="@${ZENML_SECRET_FILE}" >/dev/null
else
    zenml secret create "${ZENML_ARTIFACT_SECRET}" --values="@${ZENML_SECRET_FILE}" >/dev/null
fi

MINIO_CLIENT_KWARGS="$(printf '{"endpoint_url":"%s","region_name":"us-east-1"}' "${MINIO_ENDPOINT}")"
if component_exists artifact-store "${ZENML_ARTIFACT_STORE}"; then
    zenml artifact-store update "${ZENML_ARTIFACT_STORE}" \
        --path="s3://${MINIO_BUCKET}" \
        --authentication_secret="${ZENML_ARTIFACT_SECRET}" \
        --client_kwargs="${MINIO_CLIENT_KWARGS}" >/dev/null
else
    zenml artifact-store register "${ZENML_ARTIFACT_STORE}" \
        --flavor=s3 \
        --path="s3://${MINIO_BUCKET}" \
        --authentication_secret="${ZENML_ARTIFACT_SECRET}" \
        --client_kwargs="${MINIO_CLIENT_KWARGS}" >/dev/null
fi

if component_exists container-registry "${ZENML_CONTAINER_REGISTRY}"; then
    zenml container-registry update "${ZENML_CONTAINER_REGISTRY}" --uri="${REGISTRY_URI}" >/dev/null
else
    zenml container-registry register "${ZENML_CONTAINER_REGISTRY}" \
        --flavor=default \
        --uri="${REGISTRY_URI}" >/dev/null
fi

if component_exists image-builder "${ZENML_IMAGE_BUILDER}"; then
    IMAGE_BUILDER_FLAVOR="$("${ZENML_PYTHON}" - "${ZENML_IMAGE_BUILDER}" <<'PY'
import sys
from zenml.client import Client
from zenml.enums import StackComponentType
print(Client().get_stack_component(StackComponentType.IMAGE_BUILDER, sys.argv[1]).flavor_name)
PY
)"
    [[ "${IMAGE_BUILDER_FLAVOR}" == "local" ]] \
        || die "Image builder ${ZENML_IMAGE_BUILDER} uses flavor ${IMAGE_BUILDER_FLAVOR}; expected local."
else
    zenml image-builder register "${ZENML_IMAGE_BUILDER}" --flavor=local >/dev/null
fi

MLFLOW_TOKEN="$(oc create token "${ZENML_ORCHESTRATOR_SA}" \
    -n "${ZENML_WORKLOAD_NAMESPACE}" \
    --duration="${ZENML_MLFLOW_TOKEN_DURATION}")"
if component_exists experiment-tracker "${ZENML_EXPERIMENT_TRACKER}"; then
    zenml experiment-tracker update "${ZENML_EXPERIMENT_TRACKER}" \
        --tracking_uri="${MLFLOW_URL}" \
        --tracking_token="${MLFLOW_TOKEN}" \
        --env="MLFLOW_WORKSPACE=${ZENML_WORKLOAD_NAMESPACE}" >/dev/null
else
    zenml experiment-tracker register "${ZENML_EXPERIMENT_TRACKER}" \
        --flavor=mlflow \
        --tracking_uri="${MLFLOW_URL}" \
        --tracking_token="${MLFLOW_TOKEN}" \
        --env="MLFLOW_WORKSPACE=${ZENML_WORKLOAD_NAMESPACE}" >/dev/null
fi
unset MLFLOW_TOKEN

if zenml stack describe "${ZENML_STACK}" >/dev/null 2>&1; then
    zenml stack update "${ZENML_STACK}" \
        -o "${ZENML_ORCHESTRATOR}" \
        -a "${ZENML_ARTIFACT_STORE}" \
        -c "${ZENML_CONTAINER_REGISTRY}" \
        -i "${ZENML_IMAGE_BUILDER}" \
        -e "${ZENML_EXPERIMENT_TRACKER}" >/dev/null
else
    zenml stack register "${ZENML_STACK}" \
        -o "${ZENML_ORCHESTRATOR}" \
        -a "${ZENML_ARTIFACT_STORE}" \
        -c "${ZENML_CONTAINER_REGISTRY}" \
        -i "${ZENML_IMAGE_BUILDER}" \
        -e "${ZENML_EXPERIMENT_TRACKER}" \
        --set >/dev/null
fi
zenml stack set "${ZENML_STACK}" >/dev/null

section "ZenML remote stack bootstrap completed"
echo "    OpenShift cluster:    ${OPENSHIFT_SERVER}"
echo "    Workload project:    ${ZENML_WORKLOAD_NAMESPACE}"
echo "    Orchestrator SA:     ${ZENML_ORCHESTRATOR_SA}"
echo "    MinIO endpoint:      ${MINIO_ENDPOINT}"
echo "    Artifact bucket:     s3://${MINIO_BUCKET}"
echo "    MLflow URL:          ${MLFLOW_URL}"
echo "    Registry URI:        ${REGISTRY_URI}"
echo "    ZenML stack:         ${ZENML_STACK} (active)"
echo "    Orchestrator:        ${ZENML_ORCHESTRATOR}"
echo "    Artifact store:      ${ZENML_ARTIFACT_STORE}"
echo "    Container registry:  ${ZENML_CONTAINER_REGISTRY}"
echo "    Image builder:       ${ZENML_IMAGE_BUILDER}"
echo "    Experiment tracker:  ${ZENML_EXPERIMENT_TRACKER}"
echo
echo "Next commands:"
echo "    just validate-stack"
