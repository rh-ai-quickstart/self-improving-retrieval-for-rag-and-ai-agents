#!/usr/bin/env bash

delete_server_load_config() {
    local config_file="$1"

    section "Loading deletion configuration"

    [[ -f "${config_file}" ]] || die "Configuration file not found: ${config_file}"
    info "Environment file: ${config_file}"

    # shellcheck disable=SC1090
    source "${config_file}"

    ZENML_NAMESPACE="${ZENML_NAMESPACE:-zenml}"
    ZENML_RELEASE="${ZENML_RELEASE:-zenml-server}"
    ZENML_SERVICE="${ZENML_SERVICE:-zenml-server}"
    ZENML_ROUTE="${ZENML_ROUTE:-zenml-server}"
    ZENML_DB_SERVICE="${ZENML_DB_SERVICE:-zenml-mysql}"
    ZENML_DB_PASSWORD_SECRET="${ZENML_DB_PASSWORD_SECRET:-zenml-db-password}"
    ZENML_DELETE_CONFIRM="${ZENML_DELETE_CONFIRM:-}"

    command -v oc >/dev/null 2>&1 || die "Required command not found: oc"
    command -v helm >/dev/null 2>&1 || die "Required command not found: helm"

    oc whoami >/dev/null 2>&1 || die "The oc CLI is not authenticated to an OpenShift cluster."
    OPENSHIFT_USER="$(oc whoami)"
    OPENSHIFT_SERVER="$(oc whoami --show-server)"

    info "OpenShift user:    ${OPENSHIFT_USER}"
    info "OpenShift cluster: ${OPENSHIFT_SERVER}"
    info "OpenShift project: ${ZENML_NAMESPACE}"
}

delete_server_show_resources() {
    if ! oc get project "${ZENML_NAMESPACE}" >/dev/null 2>&1; then
        success "Project ${ZENML_NAMESPACE} does not exist or is not accessible; nothing was deleted."
        exit 0
    fi

    section "Resources selected for deletion"

    echo "    Helm release and its chart-managed resources:"
    echo "      ${ZENML_RELEASE}"
    echo
    echo "    OpenShift Route:"
    echo "      route/${ZENML_ROUTE}"
    echo
    echo "    Persistent MySQL resources:"
    echo "      deploymentconfig/${ZENML_DB_SERVICE}"
    echo "      service/${ZENML_DB_SERVICE}"
    echo "      secret/${ZENML_DB_SERVICE}"
    echo "      persistentvolumeclaim/${ZENML_DB_SERVICE}"
    echo "      secret/${ZENML_DB_PASSWORD_SECRET}"
    echo
    echo "    Additional chart-owned PVCs carrying this Helm instance label:"
    echo "      app.kubernetes.io/instance=${ZENML_RELEASE}"
    echo
    echo "    The OpenShift project ${ZENML_NAMESPACE} will be retained."

    echo
    echo "Current matching resources:"
    helm status "${ZENML_RELEASE}" -n "${ZENML_NAMESPACE}" 2>/dev/null \
        | awk '/^(NAME|STATUS|REVISION):/ {print "    " $0}' \
        || info "Helm release ${ZENML_RELEASE} is not present."

    oc get \
        "route/${ZENML_ROUTE}" \
        "deploymentconfig/${ZENML_DB_SERVICE}" \
        "service/${ZENML_DB_SERVICE}" \
        "secret/${ZENML_DB_SERVICE}" \
        "persistentvolumeclaim/${ZENML_DB_SERVICE}" \
        "secret/${ZENML_DB_PASSWORD_SECRET}" \
        -n "${ZENML_NAMESPACE}" \
        --ignore-not-found \
        2>/dev/null || true
}

delete_server_confirm() {
    section "Confirming destructive deletion"

    echo "    WARNING: This permanently deletes the MySQL PVC and all ZenML data."
    echo "    This operation does not delete the OpenShift project."
    echo

    if [[ -z "${ZENML_DELETE_CONFIRM}" ]]; then
        if [[ ! -t 0 ]]; then
            die "Interactive confirmation is unavailable. Set ZENML_DELETE_CONFIRM=${ZENML_NAMESPACE} to confirm explicitly."
        fi
        read -r -p "Type '${ZENML_NAMESPACE}' to delete these resources: " ZENML_DELETE_CONFIRM
    fi

    if [[ "${ZENML_DELETE_CONFIRM}" != "${ZENML_NAMESPACE}" ]]; then
        die "Confirmation did not match ${ZENML_NAMESPACE}; nothing was deleted."
    fi

    success "Deletion confirmed for project ${ZENML_NAMESPACE}."
}

delete_server_execute() {
    section "Deleting the public OpenShift Route"

    oc delete "route/${ZENML_ROUTE}" \
        -n "${ZENML_NAMESPACE}" \
        --ignore-not-found
    success "Route deletion completed."

    section "Uninstalling the ZenML Helm release"

    if helm status "${ZENML_RELEASE}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1; then
        helm uninstall "${ZENML_RELEASE}" \
            -n "${ZENML_NAMESPACE}" \
            --wait \
            --timeout 5m
        success "Helm release ${ZENML_RELEASE} was uninstalled."
    else
        info "Helm release ${ZENML_RELEASE} was not found; skipping Helm uninstall."
    fi

    section "Deleting the persistent MySQL database"

    oc delete \
        "deploymentconfig/${ZENML_DB_SERVICE}" \
        "service/${ZENML_DB_SERVICE}" \
        "secret/${ZENML_DB_SERVICE}" \
        "persistentvolumeclaim/${ZENML_DB_SERVICE}" \
        "secret/${ZENML_DB_PASSWORD_SECRET}" \
        -n "${ZENML_NAMESPACE}" \
        --ignore-not-found

    success "MySQL workload, Services, Secrets, and primary PVC were deleted."

    section "Deleting any remaining chart-owned PVCs"

    REMAINING_PVCS="$(oc get pvc \
        -n "${ZENML_NAMESPACE}" \
        -l "app.kubernetes.io/instance=${ZENML_RELEASE}" \
        -o name 2>/dev/null || true)"

    if [[ -n "${REMAINING_PVCS}" ]]; then
        info "Deleting: ${REMAINING_PVCS//$'\n'/, }"
        oc delete pvc \
            -n "${ZENML_NAMESPACE}" \
            -l "app.kubernetes.io/instance=${ZENML_RELEASE}"
        success "Remaining chart-owned PVCs were deleted."
    else
        info "No additional chart-owned PVCs were found."
    fi
}

delete_server_verify() {
    section "Verifying teardown"

    REMAINING_RESOURCES="$(oc get \
        "route/${ZENML_ROUTE}" \
        "deployment/${ZENML_RELEASE}" \
        "service/${ZENML_SERVICE}" \
        "deploymentconfig/${ZENML_DB_SERVICE}" \
        "service/${ZENML_DB_SERVICE}" \
        "persistentvolumeclaim/${ZENML_DB_SERVICE}" \
        -n "${ZENML_NAMESPACE}" \
        --ignore-not-found \
        -o name 2>/dev/null || true)"

    if [[ -n "${REMAINING_RESOURCES}" ]]; then
        echo "    Remaining resources:" >&2
        echo "${REMAINING_RESOURCES}" | sed 's/^/      /' >&2
        die "Teardown completed with resources still present."
    fi

    success "All selected ZenML server and MySQL resources were removed."

    section "Teardown completed"

    echo "    OpenShift cluster: ${OPENSHIFT_SERVER}"
    echo "    OpenShift project: ${ZENML_NAMESPACE} (retained)"
    echo "    Helm release:      ${ZENML_RELEASE} (removed)"
    echo "    OpenShift Route:   ${ZENML_ROUTE} (removed)"
    echo "    MySQL database:    ${ZENML_DB_SERVICE} (removed)"
    echo "    Persistent data:   deleted"
    echo
    echo "To recreate the server infrastructure:"
    echo "    just bootstrap-server"
    echo
}
