#!/usr/bin/env bash

validate_server_load_config() {
    local config_file="$1"

    section "Loading validation configuration"

    if [[ ! -f "${config_file}" ]]; then
        die "Configuration file not found: ${config_file}. Create it with: cp deployment.env.example deployment.env"
    fi

    info "Environment file: ${config_file}"
    # shellcheck disable=SC1090
    source "${config_file}"

    ZENML_NAMESPACE="${ZENML_NAMESPACE:-zenml}"
    ZENML_PYTHON="${ZENML_PYTHON:-python}"
    ZENML_VERSION="${ZENML_VERSION:-}"
    if [[ -z "${ZENML_VERSION}" ]]; then
        if command -v "${ZENML_PYTHON}" >/dev/null 2>&1; then
            ZENML_VERSION="$("${ZENML_PYTHON}" -c 'import zenml; print(zenml.__version__)' 2>/dev/null || true)"
        fi
        if [[ -z "${ZENML_VERSION}" ]]; then
            die "ZENML_VERSION is empty and could not be derived from ${ZENML_PYTHON}."
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
}
