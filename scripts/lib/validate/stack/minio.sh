#!/usr/bin/env bash

validate_stack_check_minio() {
    section "Checking MinIO and artifact storage"
    MINIO_ENDPOINT=""
    if [[ "${PROJECT_EXISTS}" != true ]]; then
        skip "MinIO checks require the workload project."
    else
        MINIO_DESIRED="$(oc get deployment minio -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
        MINIO_AVAILABLE="$(oc get deployment minio -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
        if [[ -n "${MINIO_DESIRED}" && "${MINIO_AVAILABLE:-0}" -ge "${MINIO_DESIRED}" ]]; then
            pass "MinIO Deployment is available (${MINIO_AVAILABLE}/${MINIO_DESIRED})."
        else
            fail "MinIO Deployment is not fully available (${MINIO_AVAILABLE:-0}/${MINIO_DESIRED:-unknown})."
        fi

        PVC_PHASE="$(oc get pvc minio-data -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        if [[ "${PVC_PHASE}" == Bound ]]; then
            pass "MinIO PersistentVolumeClaim is bound."
        else
            fail "MinIO PersistentVolumeClaim status is ${PVC_PHASE:-missing}; expected Bound."
        fi

        MINIO_ENDPOINTS="$(oc get endpoints minio -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{" "}{end}' 2>/dev/null || true)"
        if [[ -n "${MINIO_ENDPOINTS}" ]]; then
            pass "MinIO Service has ready endpoints: ${MINIO_ENDPOINTS}"
        else
            fail "MinIO Service has no ready endpoints."
        fi

        MINIO_ROUTE_HOST="$(oc get route "${MINIO_ROUTE_NAME}" -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
        MINIO_ROUTE_ADMITTED="$(oc get route "${MINIO_ROUTE_NAME}" -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}' 2>/dev/null || true)"
        if [[ -n "${MINIO_ROUTE_HOST}" && "${MINIO_ROUTE_ADMITTED}" == True ]]; then
            MINIO_ENDPOINT="https://${MINIO_ROUTE_HOST}"
            pass "MinIO Route is admitted: ${MINIO_ENDPOINT}"
        else
            fail "MinIO Route is missing or not admitted."
        fi

        BUCKET_JOB_COMPLETE="$(oc get job minio-bootstrap -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
        if [[ "${BUCKET_JOB_COMPLETE}" == True ]]; then
            pass "MinIO bucket bootstrap and smoke-test Job completed."
        else
            fail "MinIO bucket bootstrap Job is missing or incomplete."
        fi
    fi

    if [[ "${CURL_AVAILABLE}" == true && -n "${MINIO_ENDPOINT}" ]]; then
        if curl --fail --silent --show-error --max-time 15 "${MINIO_ENDPOINT}/minio/health/ready" >/dev/null; then
            pass "MinIO public health endpoint responded successfully."
        else
            fail "MinIO public health endpoint failed: ${MINIO_ENDPOINT}"
        fi
    else
        skip "MinIO HTTP health requires curl and an admitted Route."
    fi
}
