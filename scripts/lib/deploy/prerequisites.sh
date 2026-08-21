#!/usr/bin/env bash

deploy_check_prerequisites() {
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
}

deploy_ensure_project() {
    section "Creating or selecting the OpenShift project"

    if oc get project "${ZENML_NAMESPACE}" >/dev/null 2>&1; then
        info "Project ${ZENML_NAMESPACE} already exists; selecting it."
        oc project "${ZENML_NAMESPACE}" >/dev/null
    else
        info "Project ${ZENML_NAMESPACE} does not exist; creating it."
        oc new-project "${ZENML_NAMESPACE}" >/dev/null
    fi
    success "Using OpenShift project ${ZENML_NAMESPACE}"
}

deploy_check_storage_and_template() {
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
}
