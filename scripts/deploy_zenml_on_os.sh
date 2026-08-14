#!/usr/bin/env bash
set -euo pipefail

# Deploy ZenML OSS and a persistent MySQL database on OpenShift.
#
# Usage:
#   ./scripts/deploy_zenml_on_os.sh [deployment.env]
#
# If no path is supplied, deployment.env in the repository root is used.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${1:-${REPO_ROOT}/deployment.env}"
VALUES_FILE="${REPO_ROOT}/openshift-values.yaml"

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

validate_dns_name() {
    local label="$1"
    local value="$2"

    if [[ ! "${value}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
        die "${label} must be a lowercase DNS label: ${value}"
    fi
}

cleanup_files=()
cleanup() {
    local file
    for file in "${cleanup_files[@]:-}"; do
        [[ -z "${file}" ]] && continue
        rm -f -- "${file}"
    done
    return 0
}
trap cleanup EXIT

section "Loading deployment configuration"

[[ -f "${CONFIG_FILE}" ]] || die "Configuration file not found: ${CONFIG_FILE}. Copy deployment.env.example to deployment.env and edit it first."
[[ -f "${VALUES_FILE}" ]] || die "Helm values file not found: ${VALUES_FILE}"

info "Environment file: ${CONFIG_FILE}"
info "Helm values:     ${VALUES_FILE}"
info "The environment file is trusted input and is loaded as shell configuration."

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

ZENML_NAMESPACE="${ZENML_NAMESPACE:-zenml}"
ZENML_VERSION="${ZENML_VERSION:-0.96.2}"
ZENML_RELEASE="${ZENML_RELEASE:-zenml-server}"
ZENML_SERVICE="${ZENML_SERVICE:-zenml-server}"
ZENML_ROUTE="${ZENML_ROUTE:-zenml-server}"
ZENML_ROUTE_HOST="${ZENML_ROUTE_HOST:-}"

ZENML_DB_TEMPLATE="${ZENML_DB_TEMPLATE:-mysql-persistent}"
ZENML_DB_TEMPLATE_NAMESPACE="${ZENML_DB_TEMPLATE_NAMESPACE:-openshift}"
ZENML_DB_SERVICE="${ZENML_DB_SERVICE:-zenml-mysql}"
ZENML_DB_NAME="${ZENML_DB_NAME:-zenml}"
ZENML_DB_USER="${ZENML_DB_USER:-zenml}"
ZENML_DB_STORAGE="${ZENML_DB_STORAGE:-5Gi}"
ZENML_DB_MEMORY="${ZENML_DB_MEMORY:-1Gi}"
ZENML_DB_PASSWORD="${ZENML_DB_PASSWORD:-}"
ZENML_DB_ROOT_PASSWORD="${ZENML_DB_ROOT_PASSWORD:-}"
ZENML_DB_PASSWORD_SECRET="${ZENML_DB_PASSWORD_SECRET:-zenml-db-password}"

validate_dns_name "ZENML_NAMESPACE" "${ZENML_NAMESPACE}"
validate_dns_name "ZENML_RELEASE" "${ZENML_RELEASE}"
validate_dns_name "ZENML_SERVICE" "${ZENML_SERVICE}"
validate_dns_name "ZENML_ROUTE" "${ZENML_ROUTE}"
validate_dns_name "ZENML_DB_SERVICE" "${ZENML_DB_SERVICE}"
validate_dns_name "ZENML_DB_PASSWORD_SECRET" "${ZENML_DB_PASSWORD_SECRET}"

[[ "${ZENML_DB_NAME}" =~ ^[A-Za-z0-9_]+$ ]] || die "ZENML_DB_NAME may contain only letters, numbers, and underscores."
[[ "${ZENML_DB_USER}" =~ ^[A-Za-z0-9_]+$ ]] || die "ZENML_DB_USER may contain only letters, numbers, and underscores."

info "Resolved deployment configuration:"
info "  OpenShift project: ${ZENML_NAMESPACE}"
info "  ZenML version:     ${ZENML_VERSION}"
info "  Helm release:      ${ZENML_RELEASE}"
info "  Route:             ${ZENML_ROUTE}"
info "  Database Service:  ${ZENML_DB_SERVICE}"
info "  Database name:     ${ZENML_DB_NAME}"
info "  Database user:     ${ZENML_DB_USER}"
info "  Database storage:  ${ZENML_DB_STORAGE}"
info "  Database memory:   ${ZENML_DB_MEMORY}"
info "  Password Secret:   ${ZENML_DB_PASSWORD_SECRET}"
if [[ -n "${ZENML_ROUTE_HOST}" ]]; then
    info "  Requested hostname: ${ZENML_ROUTE_HOST}"
else
    info "  Requested hostname: assigned automatically by OpenShift"
fi
info "Database passwords are never printed."

section "Checking local prerequisites and OpenShift connectivity"

require_command oc
require_command helm
require_command curl

oc whoami >/dev/null
OPENSHIFT_USER="$(oc whoami)"
OPENSHIFT_SERVER="$(oc whoami --show-server)"

success "Authenticated to OpenShift"
info "User:    ${OPENSHIFT_USER}"
info "Cluster: ${OPENSHIFT_SERVER}"
info "Helm:    $(helm version --short)"
OC_CLIENT_VERSION="$(oc version --client 2>/dev/null | sed -n '1p')"
info "oc:      ${OC_CLIENT_VERSION:-version unavailable}"

section "Creating or selecting the OpenShift project"

if oc get project "${ZENML_NAMESPACE}" >/dev/null 2>&1; then
    info "Project ${ZENML_NAMESPACE} already exists; selecting it."
    oc project "${ZENML_NAMESPACE}" >/dev/null
else
    info "Project ${ZENML_NAMESPACE} does not exist; creating it."
    oc new-project "${ZENML_NAMESPACE}" >/dev/null
fi
success "Using OpenShift project ${ZENML_NAMESPACE}"

section "Checking persistent storage and the MySQL template"

DEFAULT_STORAGE_CLASS="$(oc get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{" "}{end}' | xargs)"
if [[ -n "${DEFAULT_STORAGE_CLASS}" ]]; then
    success "Default StorageClass available: ${DEFAULT_STORAGE_CLASS}"
else
    warn "No default StorageClass was detected. A new MySQL PVC may remain Pending."
fi

oc get template "${ZENML_DB_TEMPLATE}" -n "${ZENML_DB_TEMPLATE_NAMESPACE}" >/dev/null 2>&1 \
    || die "OpenShift template ${ZENML_DB_TEMPLATE_NAMESPACE}/${ZENML_DB_TEMPLATE} was not found."
success "MySQL template available: ${ZENML_DB_TEMPLATE_NAMESPACE}/${ZENML_DB_TEMPLATE}"

section "Provisioning the persistent MySQL database"

DATABASE_CREATED="false"
if oc get service "${ZENML_DB_SERVICE}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1; then
    info "Database Service ${ZENML_DB_SERVICE} already exists."
    info "Preserving the existing database workload, credentials, and PVC."
else
    info "No ${ZENML_DB_SERVICE} Service exists; creating a persistent MySQL deployment."
    info "The OpenShift template will create a Secret, Service, DeploymentConfig, and PVC."

    require_command openssl
    if [[ -z "${ZENML_DB_PASSWORD}" ]]; then
        ZENML_DB_PASSWORD="$(openssl rand -hex 24)"
        info "Generated a random database-user password."
    else
        info "Using the database-user password supplied in the private environment file."
    fi

    if [[ -z "${ZENML_DB_ROOT_PASSWORD}" ]]; then
        ZENML_DB_ROOT_PASSWORD="$(openssl rand -hex 24)"
        info "Generated a random MySQL root password."
    else
        info "Using the MySQL root password supplied in the private environment file."
    fi

    DB_PARAM_FILE="$(mktemp)"
    cleanup_files+=("${DB_PARAM_FILE}")
    chmod 600 "${DB_PARAM_FILE}"
    {
        printf 'DATABASE_SERVICE_NAME=%s\n' "${ZENML_DB_SERVICE}"
        printf 'MYSQL_USER=%s\n' "${ZENML_DB_USER}"
        printf 'MYSQL_PASSWORD=%s\n' "${ZENML_DB_PASSWORD}"
        printf 'MYSQL_ROOT_PASSWORD=%s\n' "${ZENML_DB_ROOT_PASSWORD}"
        printf 'MYSQL_DATABASE=%s\n' "${ZENML_DB_NAME}"
        printf 'VOLUME_CAPACITY=%s\n' "${ZENML_DB_STORAGE}"
        printf 'MEMORY_LIMIT=%s\n' "${ZENML_DB_MEMORY}"
    } > "${DB_PARAM_FILE}"

    oc process "${ZENML_DB_TEMPLATE}" \
        -n "${ZENML_DB_TEMPLATE_NAMESPACE}" \
        --param-file="${DB_PARAM_FILE}" \
        | oc apply -n "${ZENML_NAMESPACE}" -f -

    DATABASE_CREATED="true"
    success "Submitted the persistent MySQL resources."
fi

if [[ "${DATABASE_CREATED}" == "true" ]]; then
    info "Creating or updating ${ZENML_DB_PASSWORD_SECRET} for the new database."
    DB_PASSWORD_FILE="$(mktemp)"
    cleanup_files+=("${DB_PASSWORD_FILE}")
    chmod 600 "${DB_PASSWORD_FILE}"
    printf '%s' "${ZENML_DB_PASSWORD}" > "${DB_PASSWORD_FILE}"
    oc create secret generic "${ZENML_DB_PASSWORD_SECRET}" \
        -n "${ZENML_NAMESPACE}" \
        --from-file="password=${DB_PASSWORD_FILE}" \
        --dry-run=client \
        -o yaml \
        | oc apply -f -
    success "Stored the new database-user password for the ZenML Helm chart."
elif oc get secret "${ZENML_DB_PASSWORD_SECRET}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1; then
    success "ZenML database-password Secret already exists: ${ZENML_DB_PASSWORD_SECRET}"
    if [[ -n "${ZENML_DB_PASSWORD}" ]]; then
        warn "The database already existed, so the supplied password was not applied or rotated."
    fi
elif [[ -n "${ZENML_DB_PASSWORD}" ]]; then
    info "Creating ${ZENML_DB_PASSWORD_SECRET} for the ZenML Helm chart."
    DB_PASSWORD_FILE="$(mktemp)"
    cleanup_files+=("${DB_PASSWORD_FILE}")
    chmod 600 "${DB_PASSWORD_FILE}"
    printf '%s' "${ZENML_DB_PASSWORD}" > "${DB_PASSWORD_FILE}"
    oc create secret generic "${ZENML_DB_PASSWORD_SECRET}" \
        -n "${ZENML_NAMESPACE}" \
        --from-file="password=${DB_PASSWORD_FILE}" \
        --dry-run=client \
        -o yaml \
        | oc apply -f -
    success "Created the ZenML database-password Secret."
else
    die "Database ${ZENML_DB_SERVICE} already exists, but Secret ${ZENML_DB_PASSWORD_SECRET} does not. Set ZENML_DB_PASSWORD in the private environment file so the Secret can be created without changing the database password."
fi

info "Waiting for the MySQL DeploymentConfig rollout to complete."
oc rollout status "deploymentconfig/${ZENML_DB_SERVICE}" \
    -n "${ZENML_NAMESPACE}" \
    --timeout=300s
success "MySQL rollout completed."

MYSQL_POD="$(oc get pods \
    -n "${ZENML_NAMESPACE}" \
    -l "name=${ZENML_DB_SERVICE}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "${MYSQL_POD}" ]] || die "Could not locate the running MySQL pod for ${ZENML_DB_SERVICE}."

MYSQL_VERSION="$(oc exec -n "${ZENML_NAMESPACE}" "${MYSQL_POD}" -- mysql --version 2>/dev/null || true)"
MYSQL_VERSION="${MYSQL_VERSION:-version detection unavailable}"
MYSQL_SERVICE_IP="$(oc get service "${ZENML_DB_SERVICE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{.spec.clusterIP}')"
MYSQL_PVC="$(oc get pvc -n "${ZENML_NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.phase}{"("}{.spec.resources.requests.storage}{") "}{end}' | xargs)"
ZENML_DATABASE_URL="mysql://${ZENML_DB_USER}@${ZENML_DB_SERVICE}:3306/${ZENML_DB_NAME}"

info "Database pod:      ${MYSQL_POD}"
info "Database Service:  ${ZENML_DB_SERVICE}:3306 (${MYSQL_SERVICE_IP})"
info "ZenML DB URL:      ${ZENML_DATABASE_URL}"
info "Detected version:  ${MYSQL_VERSION}"
info "Namespace PVCs:    ${MYSQL_PVC:-none found}"

section "Checking the current Helm release state"

if helm status "${ZENML_RELEASE}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1; then
    HELM_STATUS="$(helm status "${ZENML_RELEASE}" -n "${ZENML_NAMESPACE}" | awk '/^STATUS:/ {print $2}')"
    info "Existing release status: ${HELM_STATUS:-unknown}"
    if [[ "${HELM_STATUS}" == pending-* ]]; then
        helm history "${ZENML_RELEASE}" -n "${ZENML_NAMESPACE}" || true
        die "Helm release ${ZENML_RELEASE} is ${HELM_STATUS}. Resolve the pending operation or roll back to the latest deployed revision before retrying."
    fi
else
    info "No existing Helm release was found; this will be a new installation."
fi

section "Installing or upgrading ZenML with Helm"

info "Chart:     oci://public.ecr.aws/zenml/zenml"
info "Version:   ${ZENML_VERSION}"
info "Release:   ${ZENML_RELEASE}"
info "Namespace: ${ZENML_NAMESPACE}"
info "Values:    ${VALUES_FILE}"
info "Database settings are supplied as non-secret Helm overrides."

helm upgrade --install "${ZENML_RELEASE}" \
    oci://public.ecr.aws/zenml/zenml \
    --version "${ZENML_VERSION}" \
    --namespace "${ZENML_NAMESPACE}" \
    --values "${VALUES_FILE}" \
    --set-string "server.database.url=${ZENML_DATABASE_URL}" \
    --set-string "server.database.passwordSecretRef.name=${ZENML_DB_PASSWORD_SECRET}" \
    --set-string "server.database.passwordSecretRef.key=password" \
    --wait \
    --timeout 5m

success "Helm installation/upgrade completed."

info "Waiting for the ZenML server Deployment rollout."
oc rollout status "deployment/${ZENML_RELEASE}" \
    -n "${ZENML_NAMESPACE}" \
    --timeout=180s
success "ZenML server rollout completed."

section "Creating or verifying the OpenShift Route"

if oc get route "${ZENML_ROUTE}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1; then
    info "Route ${ZENML_ROUTE} already exists; preserving it."
    if [[ -n "${ZENML_ROUTE_HOST}" ]]; then
        CURRENT_ROUTE_HOST="$(oc get route "${ZENML_ROUTE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{.spec.host}')"
        if [[ "${CURRENT_ROUTE_HOST}" != "${ZENML_ROUTE_HOST}" ]]; then
            warn "Existing Route hostname ${CURRENT_ROUTE_HOST} differs from requested hostname ${ZENML_ROUTE_HOST}; the existing Route was not changed."
        fi
    fi
else
    info "Creating an edge-terminated HTTPS Route for Service ${ZENML_SERVICE}."
    ROUTE_ARGS=(
        create route edge "${ZENML_ROUTE}"
        "--service=${ZENML_SERVICE}"
        "--insecure-policy=Redirect"
        -n "${ZENML_NAMESPACE}"
    )
    if [[ -n "${ZENML_ROUTE_HOST}" ]]; then
        ROUTE_ARGS+=("--hostname=${ZENML_ROUTE_HOST}")
    fi
    oc "${ROUTE_ARGS[@]}"
    success "Created OpenShift Route ${ZENML_ROUTE}."
fi

ROUTE_HOST="$(oc get route "${ZENML_ROUTE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{.spec.host}')"
ZENML_URL="https://${ROUTE_HOST}"
info "Route host: ${ROUTE_HOST}"
info "ZenML URL:  ${ZENML_URL}"

section "Checking ZenML health through the public Route"

HEALTHY="false"
for attempt in {1..30}; do
    info "Health check ${attempt}/30: ${ZENML_URL}/health"
    if curl --fail --silent --show-error "${ZENML_URL}/health" >/dev/null; then
        HEALTHY="true"
        break
    fi
    sleep 2
done

if [[ "${HEALTHY}" != "true" ]]; then
    echo
    echo "Useful diagnostics:"
    echo "  oc get pods -n ${ZENML_NAMESPACE}"
    echo "  oc get events -n ${ZENML_NAMESPACE} --sort-by='.lastTimestamp'"
    echo "  oc logs -n ${ZENML_NAMESPACE} deployment/${ZENML_RELEASE}"
    die "ZenML health check failed after 30 attempts."
fi
success "ZenML /health endpoint is responding."

if curl --fail --silent --show-error "${ZENML_URL}/ready" >/dev/null; then
    success "ZenML /ready endpoint is responding."
else
    warn "The /health endpoint passed, but /ready did not respond successfully."
fi

HELM_REVISION="$(helm status "${ZENML_RELEASE}" -n "${ZENML_NAMESPACE}" | awk '/^REVISION:/ {print $2}')"
HELM_STATUS="$(helm status "${ZENML_RELEASE}" -n "${ZENML_NAMESPACE}" | awk '/^STATUS:/ {print $2}')"

section "Provisioned OpenShift resources"

oc get deployment,deploymentconfig,service,pvc,route \
    -n "${ZENML_NAMESPACE}" \
    -o wide

section "ZenML deployment completed successfully"

echo "    OpenShift cluster:    ${OPENSHIFT_SERVER}"
echo "    OpenShift user:       ${OPENSHIFT_USER}"
echo "    OpenShift project:    ${ZENML_NAMESPACE}"
echo
echo "    ZenML version:        ${ZENML_VERSION}"
echo "    Helm release:         ${ZENML_RELEASE}"
echo "    Helm revision:        ${HELM_REVISION:-unknown}"
echo "    Helm status:          ${HELM_STATUS:-unknown}"
echo "    ZenML Service:        ${ZENML_SERVICE}"
echo "    ZenML Route:          ${ZENML_ROUTE}"
echo "    ZenML URL:            ${ZENML_URL}"
echo "    Health endpoint:      ${ZENML_URL}/health"
echo "    Readiness endpoint:   ${ZENML_URL}/ready"
echo
echo "    Database URL:         ${ZENML_DATABASE_URL}"
echo "    Database Service:     ${ZENML_DB_SERVICE}:3306"
echo "    Database ClusterIP:   ${MYSQL_SERVICE_IP}"
echo "    Database version:     ${MYSQL_VERSION}"
echo "    Database storage:     ${ZENML_DB_STORAGE} requested"
echo "    Database PVCs:        ${MYSQL_PVC:-none found}"
echo "    Password Secret:      ${ZENML_DB_PASSWORD_SECRET}"
echo
echo "Remaining manual step:"
echo "    Open ${ZENML_URL} in a browser and complete ZenML activation"
echo "    to create the initial administrator account."
echo
echo "After activation, connect the local CLI with:"
echo "    zenml login ${ZENML_URL}"
echo "    zenml status"
echo
