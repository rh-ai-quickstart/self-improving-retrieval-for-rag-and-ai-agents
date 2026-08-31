#!/usr/bin/env bash

validate_stack_check_project() {
    section "Checking the dedicated workload project and permissions"
    PROJECT_EXISTS=false
    if [[ "${OC_AVAILABLE}" != true ]]; then
        skip "OpenShift resource checks require an authenticated oc CLI."
    elif oc get project "${ZENML_WORKLOAD_NAMESPACE}" >/dev/null 2>&1; then
        PROJECT_EXISTS=true
        pass "Project exists: ${ZENML_WORKLOAD_NAMESPACE}"
    else
        fail "Project does not exist or is not accessible: ${ZENML_WORKLOAD_NAMESPACE}"
    fi

    if [[ "${PROJECT_EXISTS}" == true ]]; then
        if oc get serviceaccount "${ZENML_ORCHESTRATOR_SA}" -n "${ZENML_WORKLOAD_NAMESPACE}" >/dev/null 2>&1; then
            pass "Orchestrator service account exists: ${ZENML_ORCHESTRATOR_SA}"
        else
            fail "Orchestrator service account was not found: ${ZENML_ORCHESTRATOR_SA}"
        fi

        for resource in pods jobs; do
            if [[ "$(oc auth can-i create "${resource}" --as="system:serviceaccount:${ZENML_WORKLOAD_NAMESPACE}:${ZENML_ORCHESTRATOR_SA}" -n "${ZENML_WORKLOAD_NAMESPACE}" 2>/dev/null)" == yes ]]; then
                pass "Orchestrator service account can create ${resource}."
            else
                fail "Orchestrator service account cannot create ${resource}."
            fi
        done

        if [[ "$(oc auth can-i update imagestreams/layers --as="system:serviceaccount:${ZENML_WORKLOAD_NAMESPACE}:${ZENML_ORCHESTRATOR_SA}" -n "${ZENML_WORKLOAD_NAMESPACE}" 2>/dev/null)" == yes ]]; then
            pass "Orchestrator service account can push images to its project."
        else
            fail "Orchestrator service account cannot push images to its project."
        fi

        LINKED_PULL_SECRETS="$(oc get serviceaccount "${ZENML_ORCHESTRATOR_SA}" -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{range .imagePullSecrets[*]}{.name}{"\n"}{end}' 2>/dev/null || true)"
        if grep -Fxq "${ZENML_REGISTRY_PULL_SECRET}" <<< "${LINKED_PULL_SECRETS}"; then
            pass "Registry pull Secret is linked to the orchestrator service account."
        else
            fail "Registry pull Secret is not linked: ${ZENML_REGISTRY_PULL_SECRET}"
        fi
    fi
}
