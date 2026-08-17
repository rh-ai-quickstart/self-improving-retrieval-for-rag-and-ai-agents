#!/usr/bin/env bash
set -euo pipefail

# Refresh only the short-lived credentials used by an existing remote stack.
# This script intentionally does not provision infrastructure or registrations.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${1:-${REPO_ROOT}/deployment.env}"

# shellcheck source=stack_common.sh
source "${SCRIPT_DIR}/stack_common.sh"

jwt_expiry_utc() {
    python3 -c '
import base64
import datetime
import json
import sys

token = sys.stdin.read().strip()
try:
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    claims = json.loads(base64.urlsafe_b64decode(payload))
    expires_at = datetime.datetime.fromtimestamp(
        int(claims["exp"]), tz=datetime.timezone.utc
    )
except (IndexError, KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
    raise SystemExit(f"Unable to read token expiry: {exc}")

print(expires_at.strftime("%Y-%m-%dT%H:%M:%S"))
'
}

section "Loading credential-refresh configuration"
load_stack_config "${CONFIG_FILE}"

section "Checking existing stack and authenticated clients"
require_command oc
require_command docker
require_command zenml
require_command python3

oc whoami >/dev/null 2>&1 || die "The oc CLI is not authenticated to OpenShift."
zenml status >/dev/null 2>&1 || die "The ZenML CLI is not authenticated to the deployed server."
docker info >/dev/null 2>&1 || die "The local Docker daemon is not reachable."
oc get project "${ZENML_WORKLOAD_NAMESPACE}" >/dev/null 2>&1 \
    || die "Workload project not found: ${ZENML_WORKLOAD_NAMESPACE}. Run 'just bootstrap-stack' first."
oc get serviceaccount "${ZENML_ORCHESTRATOR_SA}" \
    -n "${ZENML_WORKLOAD_NAMESPACE}" >/dev/null 2>&1 \
    || die "Service account not found: ${ZENML_ORCHESTRATOR_SA}. Run 'just bootstrap-stack' first."
zenml service-connector describe "${ZENML_K8S_CONNECTOR}" >/dev/null 2>&1 \
    || die "Kubernetes connector not found: ${ZENML_K8S_CONNECTOR}. Run 'just bootstrap-stack' first."
zenml experiment-tracker describe "${ZENML_EXPERIMENT_TRACKER}" >/dev/null 2>&1 \
    || die "MLflow experiment tracker not found: ${ZENML_EXPERIMENT_TRACKER}. Run 'just bootstrap-stack' first."

REGISTRY_HOST="$(oc get route "${OPENSHIFT_REGISTRY_ROUTE}" \
    -n "${OPENSHIFT_REGISTRY_NAMESPACE}" \
    -o jsonpath='{.spec.host}')"
[[ -n "${REGISTRY_HOST}" ]] || die "OpenShift registry Route has no host."
MLFLOW_URL="$(oc get mlflow "${MLFLOW_INSTANCE}" -o jsonpath='{.status.url}')"
[[ "${MLFLOW_URL}" == https://* ]] || die "MLflow external URL is missing or invalid: ${MLFLOW_URL:-unavailable}"

section "Refreshing Kubernetes connector credentials"
K8S_TOKEN="$(oc create token "${ZENML_ORCHESTRATOR_SA}" \
    -n "${ZENML_WORKLOAD_NAMESPACE}" \
    --duration="${ZENML_K8S_TOKEN_DURATION}")"
K8S_EXPIRES_AT="$(printf '%s' "${K8S_TOKEN}" | jwt_expiry_utc)"
zenml service-connector update "${ZENML_K8S_CONNECTOR}" \
    --token="${K8S_TOKEN}" \
    --expires-at="${K8S_EXPIRES_AT}" \
    --expires-skew-tolerance="${ZENML_CREDENTIAL_EXPIRY_SKEW_SECONDS}" >/dev/null
unset K8S_TOKEN
zenml service-connector verify "${ZENML_K8S_CONNECTOR}" >/dev/null
success "Kubernetes connector refreshed through ${K8S_EXPIRES_AT} UTC."

section "Refreshing registry credentials"
REGISTRY_TOKEN="$(oc create token "${ZENML_ORCHESTRATOR_SA}" \
    -n "${ZENML_WORKLOAD_NAMESPACE}" \
    --duration="${ZENML_REGISTRY_TOKEN_DURATION}")"
REGISTRY_EXPIRES_AT="$(printf '%s' "${REGISTRY_TOKEN}" | jwt_expiry_utc)"
printf '%s' "${REGISTRY_TOKEN}" \
    | docker login "${REGISTRY_HOST}" \
        --username "${OPENSHIFT_REGISTRY_USERNAME}" \
        --password-stdin >/dev/null
oc create secret docker-registry "${ZENML_REGISTRY_PULL_SECRET}" \
    -n "${ZENML_WORKLOAD_NAMESPACE}" \
    --docker-server="${REGISTRY_HOST}" \
    --docker-username="${OPENSHIFT_REGISTRY_USERNAME}" \
    --docker-password="${REGISTRY_TOKEN}" \
    --dry-run=client \
    -o yaml \
    | oc apply -f - >/dev/null
unset REGISTRY_TOKEN
oc annotate secret "${ZENML_REGISTRY_PULL_SECRET}" \
    -n "${ZENML_WORKLOAD_NAMESPACE}" \
    "zenml.io/credentials-expires-at=${REGISTRY_EXPIRES_AT}Z" \
    --overwrite >/dev/null
oc secrets link "${ZENML_ORCHESTRATOR_SA}" "${ZENML_REGISTRY_PULL_SECRET}" \
    -n "${ZENML_WORKLOAD_NAMESPACE}" \
    --for=pull >/dev/null
success "Registry credentials refreshed through ${REGISTRY_EXPIRES_AT} UTC."

section "Refreshing MLflow credentials"
MLFLOW_TOKEN="$(oc create token "${ZENML_ORCHESTRATOR_SA}" \
    -n "${ZENML_WORKLOAD_NAMESPACE}" \
    --duration="${ZENML_MLFLOW_TOKEN_DURATION}")"
MLFLOW_EXPIRES_AT="$(printf '%s' "${MLFLOW_TOKEN}" | jwt_expiry_utc)"
zenml experiment-tracker update "${ZENML_EXPERIMENT_TRACKER}" \
    --tracking_uri="${MLFLOW_URL}" \
    --tracking_token="${MLFLOW_TOKEN}" \
    --env="MLFLOW_WORKSPACE=${ZENML_WORKLOAD_NAMESPACE}" >/dev/null
unset MLFLOW_TOKEN
success "MLflow credentials refreshed through ${MLFLOW_EXPIRES_AT} UTC."

section "Stack credentials refreshed"
echo "    Kubernetes connector: ${K8S_EXPIRES_AT} UTC"
echo "    Registry credentials: ${REGISTRY_EXPIRES_AT} UTC"
echo "    MLflow credentials:   ${MLFLOW_EXPIRES_AT} UTC"
