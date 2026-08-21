#!/usr/bin/env bash

deploy_provision_database() {
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

        run_logged oc process "${ZENML_DB_TEMPLATE}" \
            -n "${ZENML_DB_TEMPLATE_NAMESPACE}" \
            --param-file="${DB_PARAM_FILE}" \
            | run_logged oc apply -n "${ZENML_NAMESPACE}" -f -

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
}
