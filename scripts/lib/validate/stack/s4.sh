#!/usr/bin/env bash

validate_stack_check_s4() {
    section "Checking S4 and artifact storage"
    S4_ENDPOINT=""
    if [[ "${OC_AVAILABLE}" != true || "${WORKLOAD_PROJECT_AVAILABLE}" != true ]]; then
        skip "S4 checks require the workload project."
    else
        S4_DESIRED="$(oc get deployment s4 -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
        S4_AVAILABLE="$(oc get deployment s4 -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
        if [[ -n "${S4_DESIRED}" && "${S4_AVAILABLE:-0}" -ge "${S4_DESIRED}" ]]; then
            pass "S4 Deployment is available (${S4_AVAILABLE}/${S4_DESIRED})."
        else
            fail "S4 Deployment is not fully available (${S4_AVAILABLE:-0}/${S4_DESIRED:-unknown})."
        fi

        PVC_PHASE="$(oc get pvc s4-data -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        if [[ "${PVC_PHASE}" == "Bound" ]]; then
            pass "S4 PersistentVolumeClaim is bound."
        else
            fail "S4 PersistentVolumeClaim status is ${PVC_PHASE:-missing}; expected Bound."
        fi

        S4_ENDPOINTS="$(oc get endpoints s4 -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{" "}{end}' 2>/dev/null || true)"
        if [[ -n "${S4_ENDPOINTS}" ]]; then
            pass "S4 Service has ready endpoints: ${S4_ENDPOINTS}"
        else
            fail "S4 Service has no ready endpoints."
        fi

        S4_UI_ROUTE_HOST="$(oc get route "${S4_UI_ROUTE_NAME}" -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
        S4_UI_ROUTE_ADMITTED="$(oc get route "${S4_UI_ROUTE_NAME}" -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}' 2>/dev/null || true)"
        if [[ -n "${S4_UI_ROUTE_HOST}" && "${S4_UI_ROUTE_ADMITTED}" == True ]]; then
            S4_UI_ENDPOINT="https://${S4_UI_ROUTE_HOST}"
            pass "S4 UI Route is admitted: ${S4_UI_ENDPOINT}"
        else
            fail "S4 UI Route is missing or not admitted."
        fi

        S4_API_ROUTE_HOST="$(oc get route "${S4_API_ROUTE_NAME}" -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
        S4_API_ROUTE_ADMITTED="$(oc get route "${S4_API_ROUTE_NAME}" -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}' 2>/dev/null || true)"
        if [[ -n "${S4_API_ROUTE_HOST}" && "${S4_API_ROUTE_ADMITTED}" == True ]]; then
            S4_ENDPOINT="https://${S4_API_ROUTE_HOST}"
            pass "S4 S3 API Route is admitted: ${S4_ENDPOINT}"
        else
            fail "S4 S3 API Route is missing or not admitted."
        fi

        BUCKET_JOB_COMPLETE="$(oc get job s4-bootstrap -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
        if [[ "${BUCKET_JOB_COMPLETE}" == "True" ]]; then
            pass "S4 bucket bootstrap and smoke-test Job completed."
        else
            fail "S4 bucket bootstrap Job is missing or incomplete."
        fi
    fi

    if [[ "${CURL_AVAILABLE}" == true && -n "${S4_UI_ENDPOINT:-}" ]]; then
        if curl --fail --silent --show-error --max-time 15 "${S4_UI_ENDPOINT}/api" >/dev/null; then
            pass "S4 public UI health endpoint responded successfully."
        else
            fail "S4 public UI health endpoint failed: ${S4_UI_ENDPOINT}/api"
        fi
    else
        skip "S4 UI HTTP health requires curl and an admitted Route."
    fi
}
