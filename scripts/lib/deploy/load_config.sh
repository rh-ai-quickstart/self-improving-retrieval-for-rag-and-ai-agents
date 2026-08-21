#!/usr/bin/env bash

deploy_load_config() {
    local config_file="$1"
    local values_file="$2"

    section "Loading deployment configuration"

    [[ -f "${config_file}" ]] || die "Configuration file not found: ${config_file}. Copy deployment.env.example to deployment.env and edit it first."
    [[ -f "${values_file}" ]] || die "Helm values file not found: ${values_file}"

    info "Environment file: ${config_file}"
    info "Helm values:     ${values_file}"
    info "The environment file is trusted input and is loaded as shell configuration."

    # shellcheck disable=SC1090
    source "${config_file}"

    ZENML_NAMESPACE="${ZENML_NAMESPACE:-zenml}"
    ZENML_PYTHON="${ZENML_PYTHON:-python}"
    ZENML_VERSION="${ZENML_VERSION:-}"
    if [[ -z "${ZENML_VERSION}" ]]; then
        require_command "${ZENML_PYTHON}"
        ZENML_VERSION="$("${ZENML_PYTHON}" -c 'import zenml; print(zenml.__version__)')" \
            || die "Could not derive ZENML_VERSION from ${ZENML_PYTHON}."
    fi
    ZENML_RELEASE="${ZENML_RELEASE:-zenml-server}"
    ZENML_SERVICE="${ZENML_SERVICE:-zenml-server}"
    ZENML_ROUTE="${ZENML_ROUTE:-zenml-server}"
    ZENML_ROUTE_HOST="${ZENML_ROUTE_HOST:-}"

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
}
