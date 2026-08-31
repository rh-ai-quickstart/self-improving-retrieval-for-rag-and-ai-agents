#!/usr/bin/env bash

validate_server_check_zenml_workload() {
    section "Checking the ZenML server workload"

    if [[ "${PROJECT_EXISTS}" == "true" ]] && oc get deployment "${ZENML_RELEASE}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1; then
        ZENML_DESIRED="$(oc get deployment "${ZENML_RELEASE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{.spec.replicas}')"
        ZENML_AVAILABLE="$(oc get deployment "${ZENML_RELEASE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{.status.availableReplicas}')"
        ZENML_READY="$(oc get deployment "${ZENML_RELEASE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{.status.readyReplicas}')"

        if [[ -n "${ZENML_DESIRED}" && "${ZENML_AVAILABLE:-0}" -ge "${ZENML_DESIRED}" && "${ZENML_READY:-0}" -ge "${ZENML_DESIRED}" ]]; then
            pass "ZenML Deployment is available (${ZENML_READY}/${ZENML_DESIRED} ready)."
        else
            fail "ZenML Deployment is not fully ready (${ZENML_READY:-0}/${ZENML_DESIRED:-unknown} ready)."
        fi
        oc get deployment "${ZENML_RELEASE}" -n "${ZENML_NAMESPACE}" -o wide
    else
        fail "ZenML Deployment was not found: ${ZENML_RELEASE}"
    fi

    if [[ "${PROJECT_EXISTS}" == "true" ]] && oc get service "${ZENML_SERVICE}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1; then
        ZENML_SERVICE_IP="$(oc get service "${ZENML_SERVICE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{.spec.clusterIP}')"
        ZENML_SERVICE_PORT="$(oc get service "${ZENML_SERVICE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{.spec.ports[0].port}')"
        ZENML_ENDPOINTS="$(oc get endpoints "${ZENML_SERVICE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{" "}{end}' 2>/dev/null || true)"
        pass "ZenML Service exists: ${ZENML_SERVICE} (${ZENML_SERVICE_IP}:${ZENML_SERVICE_PORT})"
        if [[ -n "${ZENML_ENDPOINTS}" ]]; then
            pass "ZenML Service has ready endpoints: ${ZENML_ENDPOINTS}"
        else
            fail "ZenML Service has no ready endpoints."
        fi
    else
        fail "ZenML Service was not found: ${ZENML_SERVICE}"
    fi
}
