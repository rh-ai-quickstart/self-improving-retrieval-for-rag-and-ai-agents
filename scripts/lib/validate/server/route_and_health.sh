#!/usr/bin/env bash

validate_server_check_route() {
    section "Checking the public OpenShift Route"

    ZENML_URL="unavailable"
    ROUTE_ADMITTED="false"
    if oc get route "${ZENML_ROUTE}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1; then
        ROUTE_HOST="$(oc get route "${ZENML_ROUTE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{.spec.host}')"
        ROUTE_ADMITTED="$(oc get route "${ZENML_ROUTE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}' 2>/dev/null || true)"
        ZENML_URL="https://${ROUTE_HOST}"
        pass "Route exists: ${ZENML_ROUTE}"
        info "ZenML URL: ${ZENML_URL}"
        if [[ "${ROUTE_ADMITTED}" == "True" ]]; then
            pass "OpenShift router admitted the Route."
        else
            fail "OpenShift Route is not admitted (status: ${ROUTE_ADMITTED:-unknown})."
        fi
    else
        fail "OpenShift Route was not found: ${ZENML_ROUTE}"
    fi
}

validate_server_check_health() {
    section "Checking ZenML HTTP health"

    if [[ "${CURL_AVAILABLE}" != "true" ]]; then
        skip "HTTP checks require curl."
    elif [[ "${ZENML_URL}" == "unavailable" ]]; then
        skip "HTTP checks require an available Route."
    else
        if curl --fail --silent --show-error --max-time 15 "${ZENML_URL}/health" >/dev/null; then
            pass "Health endpoint responded successfully: ${ZENML_URL}/health"
        else
            fail "Health endpoint failed: ${ZENML_URL}/health"
        fi

        if curl --fail --silent --show-error --max-time 15 "${ZENML_URL}/ready" >/dev/null; then
            pass "Readiness endpoint responded successfully: ${ZENML_URL}/ready"
        else
            fail "Readiness endpoint failed: ${ZENML_URL}/ready"
        fi
    fi
}
