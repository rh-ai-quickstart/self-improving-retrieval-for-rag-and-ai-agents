#!/usr/bin/env bash

validate_server_check_project() {
    section "Checking the OpenShift project"

    PROJECT_EXISTS="false"
    if oc get project "${ZENML_NAMESPACE}" >/dev/null 2>&1; then
        PROJECT_EXISTS="true"
        pass "Project exists: ${ZENML_NAMESPACE}"
    else
        fail "Project does not exist or is not accessible: ${ZENML_NAMESPACE}"
    fi
}

validate_server_check_helm() {
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
}
