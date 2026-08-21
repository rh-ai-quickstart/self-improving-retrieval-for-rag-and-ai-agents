#!/usr/bin/env bash

validate_stack_check_mlflow() {
    section "Checking the shared OpenShift AI MLflow instance"
    MLFLOW_URL=""
    if [[ "${OC_AVAILABLE}" != true ]]; then
        skip "MLflow resource checks require an authenticated oc CLI."
    else
        MLFLOW_OPERATOR_STATE="$(oc get datasciencecluster "${OPENSHIFT_AI_DSC}" -o jsonpath='{.spec.components.mlflowoperator.managementState}' 2>/dev/null || true)"
        if [[ "${MLFLOW_OPERATOR_STATE}" == Managed ]]; then
            pass "OpenShift AI MLflow operator is Managed."
        else
            fail "OpenShift AI MLflow operator state is ${MLFLOW_OPERATOR_STATE:-unavailable}; expected Managed."
        fi

        MLFLOW_AVAILABLE="$(oc get mlflow "${MLFLOW_INSTANCE}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
        MLFLOW_URL="$(oc get mlflow "${MLFLOW_INSTANCE}" -o jsonpath='{.status.url}' 2>/dev/null || true)"
        if [[ "${MLFLOW_AVAILABLE}" == True ]]; then
            pass "Cluster-scoped MLflow instance is available: ${MLFLOW_INSTANCE}"
        else
            fail "MLflow instance ${MLFLOW_INSTANCE} is missing or not Available."
        fi
        MLFLOW_DESIRED="$(oc get deployment "${MLFLOW_INSTANCE}" -n "${OPENSHIFT_AI_APPLICATIONS_NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
        MLFLOW_DEPLOYMENT_AVAILABLE="$(oc get deployment "${MLFLOW_INSTANCE}" -n "${OPENSHIFT_AI_APPLICATIONS_NAMESPACE}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
        if [[ -n "${MLFLOW_DESIRED}" && "${MLFLOW_DEPLOYMENT_AVAILABLE:-0}" -ge "${MLFLOW_DESIRED}" ]]; then
            pass "MLflow Deployment is available (${MLFLOW_DEPLOYMENT_AVAILABLE}/${MLFLOW_DESIRED})."
        else
            fail "MLflow Deployment is not fully available (${MLFLOW_DEPLOYMENT_AVAILABLE:-0}/${MLFLOW_DESIRED:-unknown})."
        fi
        if [[ "${MLFLOW_URL}" == https://* ]]; then
            pass "MLflow external URL is published: ${MLFLOW_URL}"
        else
            fail "MLflow external URL is missing or invalid: ${MLFLOW_URL:-unavailable}"
        fi

        MLFLOW_ROLE_REF="$(oc get rolebinding "${MLFLOW_ROLE_BINDING}" -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{.roleRef.kind}:{.roleRef.name}' 2>/dev/null || true)"
        MLFLOW_ROLE_SUBJECTS="$(oc get rolebinding "${MLFLOW_ROLE_BINDING}" -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{range .subjects[*]}{.kind}:{.namespace}:{.name}{"\n"}{end}' 2>/dev/null || true)"
        if [[ "${MLFLOW_ROLE_REF}" == "ClusterRole:${MLFLOW_INTEGRATION_CLUSTER_ROLE}" ]] \
            && grep -Fxq "ServiceAccount:${ZENML_WORKLOAD_NAMESPACE}:${ZENML_ORCHESTRATOR_SA}" <<< "${MLFLOW_ROLE_SUBJECTS}"; then
            pass "MLflow integration RoleBinding targets the orchestrator service account."
        else
            fail "MLflow integration RoleBinding is missing or incorrectly configured: ${MLFLOW_ROLE_BINDING}"
        fi
    fi

    if [[ "${CURL_AVAILABLE}" == true && -n "${MLFLOW_URL}" ]]; then
        MLFLOW_HTTP_STATUS="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 15 "${MLFLOW_URL}" || true)"
        if [[ "${MLFLOW_HTTP_STATUS}" == 200 || "${MLFLOW_HTTP_STATUS}" == 302 || "${MLFLOW_HTTP_STATUS}" == 401 || "${MLFLOW_HTTP_STATUS}" == 403 ]]; then
            pass "MLflow external endpoint is reachable (HTTP ${MLFLOW_HTTP_STATUS})."
        else
            fail "MLflow external endpoint returned HTTP ${MLFLOW_HTTP_STATUS:-unavailable}."
        fi
    else
        skip "MLflow HTTP reachability requires curl and a published URL."
    fi
}
