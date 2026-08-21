#!/usr/bin/env bash

validate_server_check_clients() {
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
        log_error "Validation aborted: OpenShift checks cannot continue without oc."
        exit 1
    fi

    if OPENSHIFT_USER="$(oc whoami 2>/dev/null)"; then
        pass "Authenticated to OpenShift as ${OPENSHIFT_USER}"
        OPENSHIFT_SERVER="$(oc whoami --show-server 2>/dev/null || true)"
        info "Cluster: ${OPENSHIFT_SERVER:-unavailable}"
    else
        fail "The oc CLI is not authenticated to an OpenShift cluster."
    fi
}
