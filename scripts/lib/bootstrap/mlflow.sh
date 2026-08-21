#!/usr/bin/env bash

bootstrap_setup_mlflow() {
    local mlflow_template="$1"

    section "Provisioning the shared OpenShift AI MLflow instance"
    MLFLOW_OPERATOR_STATE="$(oc get datasciencecluster "${OPENSHIFT_AI_DSC}" \
        -o jsonpath='{.spec.components.mlflowoperator.managementState}' 2>/dev/null || true)"
    [[ "${MLFLOW_OPERATOR_STATE}" == "Managed" ]] \
        || die "OpenShift AI MLflow operator is ${MLFLOW_OPERATOR_STATE:-unavailable}; expected Managed on DataScienceCluster ${OPENSHIFT_AI_DSC}."
    oc get crd mlflows.mlflow.opendatahub.io >/dev/null 2>&1 \
        || die "OpenShift AI MLflow CRD mlflows.mlflow.opendatahub.io is not installed."
    oc get clusterrole "${MLFLOW_INTEGRATION_CLUSTER_ROLE}" >/dev/null 2>&1 \
        || die "OpenShift AI MLflow integration ClusterRole not found: ${MLFLOW_INTEGRATION_CLUSTER_ROLE}"

    if oc get mlflow "${MLFLOW_INSTANCE}" >/dev/null 2>&1; then
        info "Preserving existing cluster-scoped MLflow instance ${MLFLOW_INSTANCE}."
    else
        oc get storageclass "${MLFLOW_STORAGE_CLASS}" >/dev/null 2>&1 \
            || die "StorageClass not found for MLflow: ${MLFLOW_STORAGE_CLASS}"
        oc process -f "${mlflow_template}" \
            -p "MLFLOW_INSTANCE=${MLFLOW_INSTANCE}" \
            -p "MLFLOW_STORAGE_CLASS=${MLFLOW_STORAGE_CLASS}" \
            -p "MLFLOW_STORAGE_SIZE=${MLFLOW_STORAGE_SIZE}" \
            | oc apply -f - >/dev/null
        success "Created cluster-scoped MLflow instance ${MLFLOW_INSTANCE}."
    fi

    oc wait --for=condition=Available "mlflow/${MLFLOW_INSTANCE}" --timeout=300s
    oc rollout status "deployment/${MLFLOW_INSTANCE}" \
        -n "${OPENSHIFT_AI_APPLICATIONS_NAMESPACE}" \
        --timeout=180s
    MLFLOW_URL="$(oc get mlflow "${MLFLOW_INSTANCE}" -o jsonpath='{.status.url}')"
    [[ "${MLFLOW_URL}" == https://* ]] \
        || die "MLflow external URL is missing or invalid: ${MLFLOW_URL:-unavailable}"

    oc create rolebinding "${MLFLOW_ROLE_BINDING}" \
        --clusterrole="${MLFLOW_INTEGRATION_CLUSTER_ROLE}" \
        --serviceaccount="${ZENML_WORKLOAD_NAMESPACE}:${ZENML_ORCHESTRATOR_SA}" \
        -n "${ZENML_WORKLOAD_NAMESPACE}" \
        --dry-run=client \
        -o yaml \
        | oc apply -f - >/dev/null
    success "MLflow is available at ${MLFLOW_URL}; workload integration RBAC is configured."
}
