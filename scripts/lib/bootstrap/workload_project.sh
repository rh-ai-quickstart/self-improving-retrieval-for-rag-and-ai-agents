#!/usr/bin/env bash

bootstrap_ensure_workload_project() {
    section "Creating the dedicated workload project and identity"
    if oc get project "${ZENML_WORKLOAD_NAMESPACE}" >/dev/null 2>&1; then
        info "Project ${ZENML_WORKLOAD_NAMESPACE} already exists."
    else
        oc new-project "${ZENML_WORKLOAD_NAMESPACE}" >/dev/null
        success "Created project ${ZENML_WORKLOAD_NAMESPACE}."
    fi

    oc create serviceaccount "${ZENML_ORCHESTRATOR_SA}" \
        -n "${ZENML_WORKLOAD_NAMESPACE}" \
        --dry-run=client \
        -o yaml \
        | oc apply -f - >/dev/null
    oc label serviceaccount "${ZENML_ORCHESTRATOR_SA}" \
        -n "${ZENML_WORKLOAD_NAMESPACE}" \
        app.kubernetes.io/part-of=zenml-stack-bootstrap \
        --overwrite >/dev/null

    oc adm policy add-role-to-user edit \
        -z "${ZENML_ORCHESTRATOR_SA}" \
        -n "${ZENML_WORKLOAD_NAMESPACE}" >/dev/null
    oc adm policy add-role-to-user system:image-puller \
        -z "${ZENML_ORCHESTRATOR_SA}" \
        -n "${ZENML_WORKLOAD_NAMESPACE}" >/dev/null
    oc adm policy add-role-to-user system:image-builder \
        -z "${ZENML_ORCHESTRATOR_SA}" \
        -n "${ZENML_WORKLOAD_NAMESPACE}" >/dev/null

    [[ "$(oc auth can-i create pods --as="system:serviceaccount:${ZENML_WORKLOAD_NAMESPACE}:${ZENML_ORCHESTRATOR_SA}" -n "${ZENML_WORKLOAD_NAMESPACE}")" == "yes" ]] \
        || die "${ZENML_ORCHESTRATOR_SA} cannot create pods in ${ZENML_WORKLOAD_NAMESPACE}."
    [[ "$(oc auth can-i create jobs --as="system:serviceaccount:${ZENML_WORKLOAD_NAMESPACE}:${ZENML_ORCHESTRATOR_SA}" -n "${ZENML_WORKLOAD_NAMESPACE}")" == "yes" ]] \
        || die "${ZENML_ORCHESTRATOR_SA} cannot create jobs in ${ZENML_WORKLOAD_NAMESPACE}."
    [[ "$(oc auth can-i update imagestreams/layers --as="system:serviceaccount:${ZENML_WORKLOAD_NAMESPACE}:${ZENML_ORCHESTRATOR_SA}" -n "${ZENML_WORKLOAD_NAMESPACE}")" == "yes" ]] \
        || die "${ZENML_ORCHESTRATOR_SA} cannot push images in ${ZENML_WORKLOAD_NAMESPACE}."
    success "Orchestrator service account can create workloads and push project images."
}

bootstrap_setup_kserve() {
    section "Enabling OpenShift AI KServe model deployment"
    KSERVE_STATE="$(oc get datasciencecluster "${OPENSHIFT_AI_DSC}" \
        -o jsonpath='{.spec.components.kserve.managementState}' 2>/dev/null || true)"
    [[ "${KSERVE_STATE}" == "Managed" ]] \
        || die "OpenShift AI KServe is ${KSERVE_STATE:-unavailable}; expected Managed on DataScienceCluster ${OPENSHIFT_AI_DSC}."
    oc get crd inferenceservices.serving.kserve.io >/dev/null 2>&1 \
        || die "OpenShift AI KServe CRD inferenceservices.serving.kserve.io is not installed."

    oc create role "${MODEL_SERVING_ROLE}" \
        --verb=get,list,watch,create,update,patch,delete \
        --resource=inferenceservices.serving.kserve.io \
        -n "${ZENML_WORKLOAD_NAMESPACE}" \
        --dry-run=client \
        -o yaml \
        | oc apply -f - >/dev/null
    oc create rolebinding "${MODEL_SERVING_ROLE_BINDING}" \
        --role="${MODEL_SERVING_ROLE}" \
        --serviceaccount="${ZENML_WORKLOAD_NAMESPACE}:${ZENML_ORCHESTRATOR_SA}" \
        -n "${ZENML_WORKLOAD_NAMESPACE}" \
        --dry-run=client \
        -o yaml \
        | oc apply -f - >/dev/null

    [[ "$(oc auth can-i create inferenceservices.serving.kserve.io \
        --as="system:serviceaccount:${ZENML_WORKLOAD_NAMESPACE}:${ZENML_ORCHESTRATOR_SA}" \
        -n "${ZENML_WORKLOAD_NAMESPACE}")" == "yes" ]] \
        || die "${ZENML_ORCHESTRATOR_SA} cannot create KServe InferenceServices in ${ZENML_WORKLOAD_NAMESPACE}."
    success "OpenShift AI KServe is managed and the orchestrator can deploy InferenceServices."
}
