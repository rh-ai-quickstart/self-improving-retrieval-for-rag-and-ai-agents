#!/usr/bin/env bash

SERVER_CHART_PATH=""

# Create or update Kubernetes Secret ZENML_DB_PASSWORD_SECRET before Helm.
# ZenML's pre-install db-migration Job (passwordSecretRef) and Bitnami MySQL
# (mysql.auth.existingSecret) both require it to already exist. Chart
# secrets.yaml is Helm values only and is not this Kubernetes Secret.
# Keys: password (ZenML), mysql-password (Bitnami user, same value),
# mysql-root-password (Bitnami root).
deploy_apply_db_password_secret() {
    local password_file root_password_file
    password_file="$(mktemp)"
    root_password_file="$(mktemp)"
    cleanup_files+=("${password_file}" "${root_password_file}")
    chmod 600 "${password_file}" "${root_password_file}"
    printf '%s' "${ZENML_DB_PASSWORD}" > "${password_file}"
    printf '%s' "${ZENML_DB_ROOT_PASSWORD}" > "${root_password_file}"
    oc create secret generic "${ZENML_DB_PASSWORD_SECRET}" \
        -n "${ZENML_NAMESPACE}" \
        --from-file="password=${password_file}" \
        --from-file="mysql-password=${password_file}" \
        --from-file="mysql-root-password=${root_password_file}" \
        --dry-run=client \
        -o yaml \
        | oc apply -f -
}

deploy_ensure_generated_db_passwords() {
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
}

deploy_prepare_database_credentials() {
    section "Preparing MySQL credentials"

    local database_exists="false"
    if oc get service "${ZENML_DB_SERVICE}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1; then
        database_exists="true"
        info "Database Service ${ZENML_DB_SERVICE} already exists; preserving the existing database workload, credentials, and PVC."
    fi

    if oc get secret "${ZENML_DB_PASSWORD_SECRET}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1; then
        success "ZenML database-password Secret already exists: ${ZENML_DB_PASSWORD_SECRET}"
        if [[ -n "${ZENML_DB_PASSWORD}" || -n "${ZENML_DB_ROOT_PASSWORD}" ]]; then
            warn "The database-password Secret already existed, so supplied passwords were not applied or rotated."
        fi
    elif [[ "${database_exists}" == "true" ]]; then
        if [[ -z "${ZENML_DB_PASSWORD}" || -z "${ZENML_DB_ROOT_PASSWORD}" ]]; then
            die "Database ${ZENML_DB_SERVICE} already exists, but Secret ${ZENML_DB_PASSWORD_SECRET} does not. Set ZENML_DB_PASSWORD and ZENML_DB_ROOT_PASSWORD in the private environment file so the Secret can be created without changing the database password."
        fi
        info "Creating ${ZENML_DB_PASSWORD_SECRET} for the ZenML Helm chart."
        deploy_apply_db_password_secret
        success "Created the ZenML database-password Secret."
    else
        info "Creating ${ZENML_DB_PASSWORD_SECRET} before Helm install."
        deploy_ensure_generated_db_passwords
        deploy_apply_db_password_secret
        success "Stored the database passwords for the ZenML Helm chart."
    fi

    ZENML_DATABASE_URL="mysql://${ZENML_DB_USER}@${ZENML_DB_SERVICE}:3306/${ZENML_DB_NAME}"
    info "ZenML DB URL: ${ZENML_DATABASE_URL}"
}

DEPLOY_HELM_VALUES=""

deploy_helm_last_deployed_revision() {
    python3 - "${ZENML_RELEASE}" "${ZENML_NAMESPACE}" <<'PY'
import json
import subprocess
import sys

release, namespace = sys.argv[1], sys.argv[2]
try:
    raw = subprocess.check_output(
        ["helm", "history", release, "-n", namespace, "-o", "json"],
        stderr=subprocess.DEVNULL,
        text=True,
    )
except subprocess.CalledProcessError:
    sys.exit(0)
data = json.loads(raw or "[]")
if isinstance(data, dict):
    data = data.get("releases") or data.get("history") or []
deployed = [
    item.get("revision")
    for item in data
    if str(item.get("status", "")).lower() == "deployed"
]
if deployed:
    print(deployed[-1])
PY
}

deploy_cleanup_failed_migration_hooks() {
    oc delete job \
        -n "${ZENML_NAMESPACE}" \
        -l "app.kubernetes.io/component=db-migration" \
        --ignore-not-found >/dev/null 2>&1 || true
}

# Uninstall never-deployed pending/failed releases so bootstrap can retry.
# If a prior revision reached deployed, roll pending upgrades back to it
# instead of deleting MySQL.
deploy_recover_stuck_helm_release() {
    section "Checking the current Helm release state"

    if ! helm status "${ZENML_RELEASE}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1; then
        info "No existing Helm release was found; this will be a new installation."
        return 0
    fi

    HELM_STATUS="$(helm status "${ZENML_RELEASE}" -n "${ZENML_NAMESPACE}" | awk '/^STATUS:/ {print $2}')"
    info "Existing release status: ${HELM_STATUS:-unknown}"

    local last_deployed
    last_deployed="$(deploy_helm_last_deployed_revision || true)"

    case "${HELM_STATUS}" in
        pending-install | pending-upgrade | pending-rollback)
            helm history "${ZENML_RELEASE}" -n "${ZENML_NAMESPACE}" || true
            if [[ -n "${last_deployed}" && "${HELM_STATUS}" != pending-install ]]; then
                warn "Helm release ${ZENML_RELEASE} is ${HELM_STATUS}; rolling back to deployed revision ${last_deployed}."
                run_logged helm rollback "${ZENML_RELEASE}" "${last_deployed}" \
                    -n "${ZENML_NAMESPACE}" \
                    --wait \
                    --timeout 10m
                deploy_cleanup_failed_migration_hooks
                success "Rolled Helm release ${ZENML_RELEASE} back to revision ${last_deployed}."
                return 0
            fi
            warn "Helm release ${ZENML_RELEASE} is ${HELM_STATUS} and never reached deployed; uninstalling so bootstrap can retry."
            run_logged helm uninstall "${ZENML_RELEASE}" \
                -n "${ZENML_NAMESPACE}" \
                --wait \
                --timeout 5m
            deploy_cleanup_failed_migration_hooks
            success "Removed the stuck Helm release ${ZENML_RELEASE}."
            ;;
        failed)
            if [[ -z "${last_deployed}" ]]; then
                warn "Helm release ${ZENML_RELEASE} failed before any revision was deployed; uninstalling so bootstrap can retry."
                run_logged helm uninstall "${ZENML_RELEASE}" \
                    -n "${ZENML_NAMESPACE}" \
                    --wait \
                    --timeout 5m
                deploy_cleanup_failed_migration_hooks
                success "Removed the failed Helm release ${ZENML_RELEASE}."
            else
                info "A previous revision is deployed (${last_deployed}); continuing with upgrade."
            fi
            ;;
        deployed)
            success "Helm release ${ZENML_RELEASE} is deployed."
            ;;
        *)
            info "Helm release ${ZENML_RELEASE} status is ${HELM_STATUS:-unknown}."
            ;;
    esac
}

deploy_mysql_is_ready() {
    local ready desired
    oc get service "${ZENML_DB_SERVICE}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1 || return 1
    oc get statefulset "${ZENML_DB_SERVICE}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1 || return 1
    ready="$(oc get statefulset "${ZENML_DB_SERVICE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    desired="$(oc get statefulset "${ZENML_DB_SERVICE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
    [[ "${ready:-0}" -ge 1 && "${ready:-0}" -ge "${desired:-1}" ]]
}

deploy_build_server_helm_args() {
    local -n helm_args_ref="$1"
    local zenml_enabled="$2"

    helm_args_ref=(
        upgrade --install "${ZENML_RELEASE}" "${SERVER_CHART_PATH}"
        --namespace "${ZENML_NAMESPACE}"
        --values "${DEPLOY_HELM_VALUES}"
        --set "zenml.enabled=${zenml_enabled}"
        --set "route.enabled=${zenml_enabled}"
        --set "zenml.server.database.url=${ZENML_DATABASE_URL}"
        --set "zenml.server.database.passwordSecretRef.name=${ZENML_DB_PASSWORD_SECRET}"
        --set "zenml.server.database.passwordSecretRef.key=password"
        --set "mysql.fullnameOverride=${ZENML_DB_SERVICE}"
        --set "mysql.auth.database=${ZENML_DB_NAME}"
        --set "mysql.auth.username=${ZENML_DB_USER}"
        --set "mysql.auth.existingSecret=${ZENML_DB_PASSWORD_SECRET}"
        --set "mysql.primary.persistence.size=${ZENML_DB_STORAGE}"
        --set "mysql.primary.resources.requests.memory=${ZENML_DB_MEMORY}"
        --set "mysql.primary.resources.limits.memory=${ZENML_DB_MEMORY}"
        --set "database.passwordSecretName=${ZENML_DB_PASSWORD_SECRET}"
        --set "database.serviceName=${ZENML_DB_SERVICE}"
        --set "database.name=${ZENML_DB_NAME}"
        --set "database.user=${ZENML_DB_USER}"
        --set "route.name=${ZENML_ROUTE}"
        --set "route.serviceName=${ZENML_SERVICE}"
    )

    helm_append_secrets_values "$1" "${SERVER_CHART_PATH}"

    if [[ -n "${ZENML_ROUTE_HOST}" ]]; then
        helm_args_ref+=(--set-string "route.host=${ZENML_ROUTE_HOST}")
    fi
    if [[ -n "${ZENML_DB_PASSWORD}" ]]; then
        helm_args_ref+=(--set-string "database.password=${ZENML_DB_PASSWORD}")
    fi
    if [[ -n "${ZENML_DB_ROOT_PASSWORD}" ]]; then
        helm_args_ref+=(--set-string "database.rootPassword=${ZENML_DB_ROOT_PASSWORD}")
    fi
}

deploy_update_chart_dependencies() {
    SERVER_CHART_PATH="${REPO_ROOT}/deploy/helm/zenml-server"
    [[ -f "${SERVER_CHART_PATH}/Chart.yaml" ]] || die "Helm chart not found: ${SERVER_CHART_PATH}"

    info "Updating chart dependencies for ZenML ${ZENML_VERSION}."
    if command -v python3 >/dev/null 2>&1; then
        python3 - "${SERVER_CHART_PATH}/Chart.yaml" "${ZENML_VERSION}" <<'PY'
import sys
from pathlib import Path

chart_path = Path(sys.argv[1])
version = sys.argv[2]
lines = chart_path.read_text(encoding="utf-8").splitlines()
output = []
in_zenml = False
for line in lines:
    if line.startswith("  - name: zenml"):
        in_zenml = True
        output.append(line)
        continue
    if in_zenml and line.startswith("    version:"):
        output.append(f'    version: "{version}"')
        in_zenml = False
        continue
    if in_zenml and line.startswith("  - name:"):
        in_zenml = False
    output.append(line)
chart_path.write_text("\n".join(output) + "\n", encoding="utf-8")
PY
    fi
    run_logged helm dependency build "${SERVER_CHART_PATH}"
    success "Chart dependencies are ready."
}

deploy_install_helm() {
    local openshift_values="$1"
    local -a helm_args

    DEPLOY_HELM_VALUES="${openshift_values}"
    deploy_update_chart_dependencies
    deploy_recover_stuck_helm_release

    section "Installing or upgrading ZenML with Helm"

    info "Chart:     ${SERVER_CHART_PATH}"
    info "Version:   ${ZENML_VERSION}"
    info "Release:   ${ZENML_RELEASE}"
    info "Namespace: ${ZENML_NAMESPACE}"
    info "Values:    ${DEPLOY_HELM_VALUES}"
    info "Password Secret: ${ZENML_DB_PASSWORD_SECRET}"
    info "Database settings are supplied as non-secret Helm overrides."
    info "ZenML db-migration is a pre-install hook; MySQL is installed and waited on first."

    oc get secret "${ZENML_DB_PASSWORD_SECRET}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1 \
        || die "Secret ${ZENML_DB_PASSWORD_SECRET} was not found in ${ZENML_NAMESPACE}. It must exist before Helm install."

    # shellcheck source=lib/helm/secrets.sh
    source "${SCRIPT_DIR}/lib/helm/secrets.sh"

    if ! deploy_mysql_is_ready; then
        section "Installing MySQL before the ZenML server"
        info "Pass 1: zenml.enabled=false so the db-migration Job cannot run before Service ${ZENML_DB_SERVICE} exists."
        deploy_build_server_helm_args helm_args false
        run_logged helm "${helm_args[@]}" --wait --timeout 10m
        success "MySQL Helm resources are installed."
    else
        info "MySQL Service ${ZENML_DB_SERVICE} is already ready; skipping the MySQL-only Helm pass."
    fi

    deploy_wait_for_mysql

    section "Installing the ZenML server"
    info "Pass 2: zenml.enabled=true. db-migration can resolve ${ZENML_DB_SERVICE} because MySQL is Ready."
    deploy_build_server_helm_args helm_args true
    run_logged helm "${helm_args[@]}" --wait --timeout 10m

    success "Helm installation/upgrade completed."
}

deploy_wait_for_mysql() {
    section "Waiting for the persistent MySQL database"

    oc get statefulset "${ZENML_DB_SERVICE}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1 \
        || die "MySQL StatefulSet was not found: ${ZENML_DB_SERVICE}"

    info "Waiting for the MySQL StatefulSet rollout to complete."
    run_logged oc rollout status "statefulset/${ZENML_DB_SERVICE}" \
        -n "${ZENML_NAMESPACE}" \
        --timeout=300s
    success "MySQL rollout completed."

    MYSQL_POD="$(oc get pods \
        -n "${ZENML_NAMESPACE}" \
        -l "app.kubernetes.io/name=mysql,app.kubernetes.io/instance=${ZENML_RELEASE}" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -z "${MYSQL_POD}" ]]; then
        MYSQL_POD="$(oc get pods \
            -n "${ZENML_NAMESPACE}" \
            -l "app.kubernetes.io/name=mysql" \
            --field-selector=status.phase=Running \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    fi
    [[ -n "${MYSQL_POD}" ]] || die "Could not locate the running MySQL pod for ${ZENML_DB_SERVICE}."

    oc get service "${ZENML_DB_SERVICE}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1 \
        || die "MySQL Service was not found: ${ZENML_DB_SERVICE}"
    MYSQL_ENDPOINTS="$(oc get endpoints "${ZENML_DB_SERVICE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{" "}{end}' 2>/dev/null || true)"
    [[ -n "${MYSQL_ENDPOINTS}" ]] || die "MySQL Service ${ZENML_DB_SERVICE} has no ready endpoints; DNS would fail for db-migration."

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
}

deploy_wait_for_zenml() {
    section "Waiting for the ZenML server Deployment"

    info "Waiting for the ZenML server Deployment rollout."
    run_logged oc rollout status "deployment/${ZENML_RELEASE}" \
        -n "${ZENML_NAMESPACE}" \
        --timeout=180s
    success "ZenML server rollout completed."
}
