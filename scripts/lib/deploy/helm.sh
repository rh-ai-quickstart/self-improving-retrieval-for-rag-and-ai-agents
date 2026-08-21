#!/usr/bin/env bash

SERVER_CHART_PATH=""

deploy_prepare_database_credentials() {
    section "Preparing MySQL credentials"

    if oc get service "${ZENML_DB_SERVICE}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1; then
        info "Database Service ${ZENML_DB_SERVICE} already exists; preserving credentials."
        if oc get secret "${ZENML_DB_PASSWORD_SECRET}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1; then
            if [[ -n "${ZENML_DB_PASSWORD}" || -n "${ZENML_DB_ROOT_PASSWORD}" ]]; then
                warn "The database already existed, so supplied passwords were not applied or rotated."
            fi
        elif [[ -z "${ZENML_DB_PASSWORD}" ]]; then
            die "Database ${ZENML_DB_SERVICE} already exists, but Secret ${ZENML_DB_PASSWORD_SECRET} does not. Set ZENML_DB_PASSWORD in deployment.env or database.password in deploy/helm/zenml-server/secrets.yaml."
        fi
    fi

    ZENML_DATABASE_URL="mysql://${ZENML_DB_USER}@${ZENML_DB_SERVICE}:3306/${ZENML_DB_NAME}"
    info "ZenML DB URL: ${ZENML_DATABASE_URL}"
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

    deploy_update_chart_dependencies

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

    info "Chart:     ${SERVER_CHART_PATH}"
    info "Version:   ${ZENML_VERSION}"
    info "Release:   ${ZENML_RELEASE}"
    info "Namespace: ${ZENML_NAMESPACE}"
    info "Values:    ${openshift_values}"

    # shellcheck source=lib/helm/secrets.sh
    source "${SCRIPT_DIR}/lib/helm/secrets.sh"

    local -a helm_args=(
        upgrade --install "${ZENML_RELEASE}" "${SERVER_CHART_PATH}"
        --namespace "${ZENML_NAMESPACE}"
        --values "${openshift_values}"
        --set "zenml.server.database.url=${ZENML_DATABASE_URL}"
        --set "zenml.server.database.passwordSecretRef.name=${ZENML_DB_PASSWORD_SECRET}"
        --set "zenml.server.database.passwordSecretRef.key=password"
        --set "mysql.fullnameOverride=${ZENML_DB_SERVICE}"
        --set "mysql.auth.database=${ZENML_DB_NAME}"
        --set "mysql.auth.username=${ZENML_DB_USER}"
        --set "mysql.auth.existingSecret=${ZENML_DB_PASSWORD_SECRET}"
        --set "mysql.auth.secretKeys.adminPasswordKey=mysql-root-password"
        --set "mysql.auth.secretKeys.userPasswordKey=password"
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

    helm_append_secrets_values helm_args "${SERVER_CHART_PATH}"

    if [[ -n "${ZENML_ROUTE_HOST}" ]]; then
        helm_args+=(--set-string "route.host=${ZENML_ROUTE_HOST}")
    fi
    if [[ -n "${ZENML_DB_PASSWORD}" ]]; then
        helm_args+=(
            --set-string "database.password=${ZENML_DB_PASSWORD}"
        )
    fi
    if [[ -n "${ZENML_DB_ROOT_PASSWORD}" ]]; then
        helm_args+=(
            --set-string "database.rootPassword=${ZENML_DB_ROOT_PASSWORD}"
        )
    fi

    run_logged helm "${helm_args[@]}" --wait --timeout 10m

    success "Helm installation/upgrade completed."

    info "Waiting for the ZenML server Deployment rollout."
    run_logged oc rollout status "deployment/${ZENML_RELEASE}" \
        -n "${ZENML_NAMESPACE}" \
        --timeout=180s
    success "ZenML server rollout completed."

    MYSQL_POD="$(oc get pods \
        -n "${ZENML_NAMESPACE}" \
        -l "app.kubernetes.io/name=mysql,app.kubernetes.io/instance=${ZENML_RELEASE}" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    MYSQL_VERSION="unavailable"
    if [[ -n "${MYSQL_POD}" ]]; then
        MYSQL_VERSION="$(oc exec -n "${ZENML_NAMESPACE}" "${MYSQL_POD}" -- mysql --version 2>/dev/null || true)"
    fi
    MYSQL_VERSION="${MYSQL_VERSION:-version detection unavailable}"
    MYSQL_SERVICE_IP="$(oc get service "${ZENML_DB_SERVICE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{.spec.clusterIP}')"
    MYSQL_PVC="$(oc get pvc -n "${ZENML_NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.phase}{"("}{.spec.resources.requests.storage}{") "}{end}' | xargs)"
}
