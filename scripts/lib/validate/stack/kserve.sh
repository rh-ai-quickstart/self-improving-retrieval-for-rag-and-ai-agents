#!/usr/bin/env bash

validate_stack_check_kserve() {
    section "Checking OpenShift AI KServe deployment capability"
    if [[ "${OC_AVAILABLE}" != true ]]; then
        skip "KServe checks require an authenticated oc CLI."
    else
        KSERVE_STATE="$(oc get datasciencecluster "${OPENSHIFT_AI_DSC}" -o jsonpath='{.spec.components.kserve.managementState}' 2>/dev/null || true)"
        if [[ "${KSERVE_STATE}" == Managed ]]; then
            pass "OpenShift AI KServe is Managed."
        else
            fail "OpenShift AI KServe state is ${KSERVE_STATE:-unavailable}; expected Managed."
        fi

        if oc get crd inferenceservices.serving.kserve.io >/dev/null 2>&1; then
            pass "KServe InferenceService CRD is installed."
        else
            fail "KServe InferenceService CRD is not installed."
        fi

        if [[ "${PROJECT_EXISTS}" == true ]]; then
            KSERVE_ROLE_REF="$(oc get rolebinding "${MODEL_SERVING_ROLE_BINDING}" -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{.roleRef.kind}:{.roleRef.name}' 2>/dev/null || true)"
            KSERVE_ROLE_SUBJECTS="$(oc get rolebinding "${MODEL_SERVING_ROLE_BINDING}" -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{range .subjects[*]}{.kind}:{.namespace}:{.name}{"\n"}{end}' 2>/dev/null || true)"
            if [[ "${KSERVE_ROLE_REF}" == "Role:${MODEL_SERVING_ROLE}" ]] \
                && grep -Fxq "ServiceAccount:${ZENML_WORKLOAD_NAMESPACE}:${ZENML_ORCHESTRATOR_SA}" <<< "${KSERVE_ROLE_SUBJECTS}"; then
                pass "KServe deployment RoleBinding targets the orchestrator service account."
            else
                fail "KServe deployment RoleBinding is missing or incorrectly configured: ${MODEL_SERVING_ROLE_BINDING}"
            fi

            for verb in get create patch delete; do
                if [[ "$(oc auth can-i "${verb}" inferenceservices.serving.kserve.io --as="system:serviceaccount:${ZENML_WORKLOAD_NAMESPACE}:${ZENML_ORCHESTRATOR_SA}" -n "${ZENML_WORKLOAD_NAMESPACE}" 2>/dev/null)" == yes ]]; then
                    pass "Orchestrator service account can ${verb} KServe InferenceServices."
                else
                    fail "Orchestrator service account cannot ${verb} KServe InferenceServices."
                fi
            done
            if [[ "$(oc auth can-i create routes.route.openshift.io --as="system:serviceaccount:${ZENML_WORKLOAD_NAMESPACE}:${ZENML_ORCHESTRATOR_SA}" -n "${ZENML_WORKLOAD_NAMESPACE}" 2>/dev/null)" == yes ]]; then
                pass "Orchestrator service account can create the search UI Route."
            else
                fail "Orchestrator service account cannot create OpenShift Routes."
            fi
        fi
    fi
}
