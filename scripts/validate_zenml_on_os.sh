#!/usr/bin/env bash
set -uo pipefail

# Validate an existing ZenML OSS deployment on OpenShift without changing it.
#
# Usage:
#   ./scripts/validate_zenml_on_os.sh [deployment.env]

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${1:-${REPO_ROOT}/deployment.env}"
FAILURES=0

section() {
    echo
    echo "======================================================================"
    echo "==> $1"
    echo "======================================================================"
}

info() {
    echo "    $1"
}

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

section "Loading validation configuration"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: Configuration file not found: ${CONFIG_FILE}" >&2
    echo "Create it with: cp deployment.env.example deployment.env" >&2
    exit 1
fi

info "Environment file: ${CONFIG_FILE}"
# shellcheck disable=SC1090
source "${CONFIG_FILE}"

ZENML_NAMESPACE="${ZENML_NAMESPACE:-zenml}"
ZENML_PYTHON="${ZENML_PYTHON:-python}"
ZENML_VERSION="${ZENML_VERSION:-}"
if [[ -z "${ZENML_VERSION}" ]]; then
    if command -v "${ZENML_PYTHON}" >/dev/null 2>&1; then
        ZENML_VERSION="$("${ZENML_PYTHON}" -c 'import zenml; print(zenml.__version__)' 2>/dev/null || true)"
    fi
    if [[ -z "${ZENML_VERSION}" ]]; then
        echo "ERROR: ZENML_VERSION is empty and could not be derived from ${ZENML_PYTHON}." >&2
        exit 1
    fi
fi
ZENML_RELEASE="${ZENML_RELEASE:-zenml-server}"
ZENML_SERVICE="${ZENML_SERVICE:-zenml-server}"
ZENML_ROUTE="${ZENML_ROUTE:-zenml-server}"
ZENML_DB_SERVICE="${ZENML_DB_SERVICE:-zenml-mysql}"
ZENML_DB_NAME="${ZENML_DB_NAME:-zenml}"
ZENML_DB_USER="${ZENML_DB_USER:-zenml}"
ZENML_DB_PASSWORD_SECRET="${ZENML_DB_PASSWORD_SECRET:-zenml-db-password}"
ZENML_DATABASE_URL="mysql://${ZENML_DB_USER}@${ZENML_DB_SERVICE}:3306/${ZENML_DB_NAME}"

info "OpenShift project: ${ZENML_NAMESPACE}"
info "ZenML version:     ${ZENML_VERSION}"
info "Helm release:      ${ZENML_RELEASE}"
info "ZenML Service:     ${ZENML_SERVICE}"
info "ZenML Route:       ${ZENML_ROUTE}"
info "Database URL:      ${ZENML_DATABASE_URL}"

section "Checking local commands and OpenShift access"

OC_AVAILABLE="false"
HELM_AVAILABLE="false"
CURL_AVAILABLE="false"
command_available oc && OC_AVAILABLE="true"
command_available helm && HELM_AVAILABLE="true"
command_available curl && CURL_AVAILABLE="true"

if [[ "${OC_AVAILABLE}" != "true" ]]; then
    fail "OpenShift checks cannot continue without oc."
    section "Validation failed"
    info "Failures: ${FAILURES}"
    exit 1
fi

if OPENSHIFT_USER="$(oc whoami 2>/dev/null)"; then
    pass "Authenticated to OpenShift as ${OPENSHIFT_USER}"
    OPENSHIFT_SERVER="$(oc whoami --show-server 2>/dev/null || true)"
    info "Cluster: ${OPENSHIFT_SERVER:-unavailable}"
else
    fail "The oc CLI is not authenticated to an OpenShift cluster."
fi

section "Checking the OpenShift project"

PROJECT_EXISTS="false"
if oc get project "${ZENML_NAMESPACE}" >/dev/null 2>&1; then
    PROJECT_EXISTS="true"
    pass "Project exists: ${ZENML_NAMESPACE}"
else
    fail "Project does not exist or is not accessible: ${ZENML_NAMESPACE}"
fi

section "Checking the Helm release"

HELM_STATUS="unavailable"
HELM_REVISION="unavailable"
if [[ "${HELM_AVAILABLE}" != "true" ]]; then
    skip "Helm release checks require helm."
elif [[ "${PROJECT_EXISTS}" != "true" ]]; then
    skip "Helm release checks require an accessible project."
elif HELM_OUTPUT="$(helm status "${ZENML_RELEASE}" -n "${ZENML_NAMESPACE}" 2>/dev/null)"; then
    HELM_STATUS="$(awk '/^STATUS:/ {print $2}' <<< "${HELM_OUTPUT}")"
    HELM_REVISION="$(awk '/^REVISION:/ {print $2}' <<< "${HELM_OUTPUT}")"

    if [[ "${HELM_STATUS}" == "deployed" ]]; then
        pass "Helm release ${ZENML_RELEASE} is deployed."
    else
        fail "Helm release ${ZENML_RELEASE} has status ${HELM_STATUS:-unknown}."
    fi
    info "Revision: ${HELM_REVISION:-unknown}"
else
    fail "Helm release was not found: ${ZENML_RELEASE}"
fi

section "Checking the ZenML server workload"

if [[ "${PROJECT_EXISTS}" == "true" ]] && oc get deployment "${ZENML_RELEASE}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1; then
    ZENML_DESIRED="$(oc get deployment "${ZENML_RELEASE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{.spec.replicas}')"
    ZENML_AVAILABLE="$(oc get deployment "${ZENML_RELEASE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{.status.availableReplicas}')"
    ZENML_READY="$(oc get deployment "${ZENML_RELEASE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{.status.readyReplicas}')"

    if [[ -n "${ZENML_DESIRED}" && "${ZENML_AVAILABLE:-0}" -ge "${ZENML_DESIRED}" && "${ZENML_READY:-0}" -ge "${ZENML_DESIRED}" ]]; then
        pass "ZenML Deployment is available (${ZENML_READY}/${ZENML_DESIRED} ready)."
    else
        fail "ZenML Deployment is not fully ready (${ZENML_READY:-0}/${ZENML_DESIRED:-unknown} ready)."
    fi
    oc get deployment "${ZENML_RELEASE}" -n "${ZENML_NAMESPACE}" -o wide
else
    fail "ZenML Deployment was not found: ${ZENML_RELEASE}"
fi

if [[ "${PROJECT_EXISTS}" == "true" ]] && oc get service "${ZENML_SERVICE}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1; then
    ZENML_SERVICE_IP="$(oc get service "${ZENML_SERVICE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{.spec.clusterIP}')"
    ZENML_SERVICE_PORT="$(oc get service "${ZENML_SERVICE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{.spec.ports[0].port}')"
    ZENML_ENDPOINTS="$(oc get endpoints "${ZENML_SERVICE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{" "}{end}' 2>/dev/null || true)"
    pass "ZenML Service exists: ${ZENML_SERVICE} (${ZENML_SERVICE_IP}:${ZENML_SERVICE_PORT})"
    if [[ -n "${ZENML_ENDPOINTS}" ]]; then
        pass "ZenML Service has ready endpoints: ${ZENML_ENDPOINTS}"
    else
        fail "ZenML Service has no ready endpoints."
    fi
else
    fail "ZenML Service was not found: ${ZENML_SERVICE}"
fi

section "Checking the persistent MySQL database"

MYSQL_VERSION="unavailable"
MYSQL_SERVICE_IP="unavailable"
MYSQL_POD=""

if [[ "${PROJECT_EXISTS}" == "true" ]] && oc get deploymentconfig "${ZENML_DB_SERVICE}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1; then
    MYSQL_AVAILABLE="$(oc get deploymentconfig "${ZENML_DB_SERVICE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{.status.availableReplicas}')"
    if [[ "${MYSQL_AVAILABLE:-0}" -ge 1 ]]; then
        pass "MySQL DeploymentConfig is available."
    else
        fail "MySQL DeploymentConfig has no available replicas."
    fi
else
    fail "MySQL DeploymentConfig was not found: ${ZENML_DB_SERVICE}"
fi

MYSQL_POD="$(oc get pods \
    -n "${ZENML_NAMESPACE}" \
    -l "name=${ZENML_DB_SERVICE}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "${MYSQL_POD}" ]]; then
    MYSQL_READY="$(oc get pod "${MYSQL_POD}" -n "${ZENML_NAMESPACE}" -o jsonpath='{.status.containerStatuses[0].ready}')"
    if [[ "${MYSQL_READY}" == "true" ]]; then
        pass "MySQL pod is ready: ${MYSQL_POD}"
    else
        fail "MySQL pod is running but not ready: ${MYSQL_POD}"
    fi
    MYSQL_VERSION="$(oc exec -n "${ZENML_NAMESPACE}" "${MYSQL_POD}" -- mysql --version 2>/dev/null || true)"
    info "Detected database version: ${MYSQL_VERSION:-unavailable}"
else
    fail "No running MySQL pod was found for ${ZENML_DB_SERVICE}."
fi

if oc get service "${ZENML_DB_SERVICE}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1; then
    MYSQL_SERVICE_IP="$(oc get service "${ZENML_DB_SERVICE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{.spec.clusterIP}')"
    MYSQL_ENDPOINTS="$(oc get endpoints "${ZENML_DB_SERVICE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{" "}{end}' 2>/dev/null || true)"
    pass "MySQL Service exists: ${ZENML_DB_SERVICE} (${MYSQL_SERVICE_IP}:3306)"
    if [[ -n "${MYSQL_ENDPOINTS}" ]]; then
        pass "MySQL Service has ready endpoints: ${MYSQL_ENDPOINTS}"
    else
        fail "MySQL Service has no ready endpoints."
    fi
else
    fail "MySQL Service was not found: ${ZENML_DB_SERVICE}"
fi

if oc get secret "${ZENML_DB_PASSWORD_SECRET}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1; then
    pass "ZenML database-password Secret exists: ${ZENML_DB_PASSWORD_SECRET}"
else
    fail "ZenML database-password Secret was not found: ${ZENML_DB_PASSWORD_SECRET}"
fi

PVC_SUMMARY="$(oc get pvc -n "${ZENML_NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.phase}{"("}{.spec.resources.requests.storage}{") "}{end}' 2>/dev/null || true)"
if [[ -n "${PVC_SUMMARY}" ]]; then
    info "PersistentVolumeClaims: ${PVC_SUMMARY}"
    UNBOUND_PVCS="$(oc get pvc -n "${ZENML_NAMESPACE}" --no-headers 2>/dev/null | awk '$2 != "Bound" {print $1}' | xargs)"
    if [[ -z "${UNBOUND_PVCS}" ]]; then
        pass "All PersistentVolumeClaims are bound."
    else
        fail "Unbound PersistentVolumeClaims: ${UNBOUND_PVCS}"
    fi
else
    fail "No PersistentVolumeClaims were found in ${ZENML_NAMESPACE}."
fi

section "Checking the public OpenShift Route"

ZENML_URL="unavailable"
ROUTE_ADMITTED="false"
if oc get route "${ZENML_ROUTE}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1; then
    ROUTE_HOST="$(oc get route "${ZENML_ROUTE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{.spec.host}')"
    ROUTE_ADMITTED="$(oc get route "${ZENML_ROUTE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}' 2>/dev/null || true)"
    ZENML_URL="https://${ROUTE_HOST}"
    pass "Route exists: ${ZENML_ROUTE}"
    info "ZenML URL: ${ZENML_URL}"
    if [[ "${ROUTE_ADMITTED}" == "True" ]]; then
        pass "OpenShift router admitted the Route."
    else
        fail "OpenShift Route is not admitted (status: ${ROUTE_ADMITTED:-unknown})."
    fi
else
    fail "OpenShift Route was not found: ${ZENML_ROUTE}"
fi

section "Checking ZenML HTTP health"

if [[ "${CURL_AVAILABLE}" != "true" ]]; then
    skip "HTTP checks require curl."
elif [[ "${ZENML_URL}" == "unavailable" ]]; then
    skip "HTTP checks require an available Route."
else
    if curl --fail --silent --show-error --max-time 15 "${ZENML_URL}/health" >/dev/null; then
        pass "Health endpoint responded successfully: ${ZENML_URL}/health"
    else
        fail "Health endpoint failed: ${ZENML_URL}/health"
    fi

    if curl --fail --silent --show-error --max-time 15 "${ZENML_URL}/ready" >/dev/null; then
        pass "Readiness endpoint responded successfully: ${ZENML_URL}/ready"
    else
        fail "Readiness endpoint failed: ${ZENML_URL}/ready"
    fi
fi

section "Validation summary"

echo "    OpenShift project:  ${ZENML_NAMESPACE}"
echo "    Helm release:       ${ZENML_RELEASE}"
echo "    Helm revision:      ${HELM_REVISION}"
echo "    Helm status:        ${HELM_STATUS}"
echo "    ZenML URL:          ${ZENML_URL}"
echo "    Database URL:       ${ZENML_DATABASE_URL}"
echo "    Database ClusterIP: ${MYSQL_SERVICE_IP}"
echo "    Database version:   ${MYSQL_VERSION:-unavailable}"
echo "    PVCs:               ${PVC_SUMMARY:-none found}"
echo

if [[ "${FAILURES}" -eq 0 ]]; then
    echo "    RESULT: PASS — ZenML server infrastructure is healthy."
    exit 0
fi

echo "    RESULT: FAIL — ${FAILURES} validation check(s) failed." >&2
exit 1
