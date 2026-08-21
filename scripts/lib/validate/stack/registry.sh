#!/usr/bin/env bash

validate_stack_check_registry() {
    section "Checking the OpenShift image registry"
    REGISTRY_HOST=""
    if [[ "${OC_AVAILABLE}" != true ]]; then
        skip "Registry checks require an authenticated oc CLI."
    else
        REGISTRY_STATE="$(oc get configs.imageregistry.operator.openshift.io cluster -o jsonpath='{.spec.managementState}' 2>/dev/null || true)"
        REGISTRY_DEFAULT_ROUTE="$(oc get configs.imageregistry.operator.openshift.io cluster -o jsonpath='{.spec.defaultRoute}' 2>/dev/null || true)"
        if [[ "${REGISTRY_STATE}" == Managed ]]; then
            pass "OpenShift image registry is Managed."
        else
            fail "OpenShift image registry state is ${REGISTRY_STATE:-unavailable}; expected Managed."
        fi
        if [[ "${REGISTRY_DEFAULT_ROUTE}" == true ]]; then
            pass "OpenShift registry default Route is enabled."
        else
            fail "OpenShift registry default Route is not enabled."
        fi

        REGISTRY_HOST="$(oc get route "${OPENSHIFT_REGISTRY_ROUTE}" -n "${OPENSHIFT_REGISTRY_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
        REGISTRY_ROUTE_ADMITTED="$(oc get route "${OPENSHIFT_REGISTRY_ROUTE}" -n "${OPENSHIFT_REGISTRY_NAMESPACE}" -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}' 2>/dev/null || true)"
        if [[ -n "${REGISTRY_HOST}" && "${REGISTRY_ROUTE_ADMITTED}" == True ]]; then
            pass "OpenShift registry Route is admitted: ${REGISTRY_HOST}"
        else
            fail "OpenShift registry Route is missing or not admitted."
        fi

        if oc get imagestream zenml -n "${ZENML_WORKLOAD_NAMESPACE}" >/dev/null 2>&1; then
            pass "ZenML ImageStream exists in the workload project."
        else
            fail "ZenML ImageStream was not found in the workload project."
        fi
    fi

    if [[ "${CURL_AVAILABLE}" == true && -n "${REGISTRY_HOST}" ]]; then
        REGISTRY_HTTP_STATUS="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 15 "https://${REGISTRY_HOST}/v2/" || true)"
        if [[ "${REGISTRY_HTTP_STATUS}" == 200 || "${REGISTRY_HTTP_STATUS}" == 401 ]]; then
            pass "Registry v2 endpoint is reachable (HTTP ${REGISTRY_HTTP_STATUS})."
        else
            fail "Registry v2 endpoint returned HTTP ${REGISTRY_HTTP_STATUS:-unavailable}."
        fi
    else
        skip "Registry HTTP health requires curl and an admitted Route."
    fi
}
