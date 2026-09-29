#!/usr/bin/env bash

ZENML_STACK_RELEASE="${ZENML_STACK_RELEASE:-zenml-stack}"
STACK_CHART_PATH=""

bootstrap_verify_openshift_ai() {
    section "Verifying OpenShift AI prerequisites"
    KSERVE_STATE="$(oc get datasciencecluster "${OPENSHIFT_AI_DSC}" \
        -o jsonpath='{.spec.components.kserve.managementState}' 2>/dev/null || true)"
    [[ "${KSERVE_STATE}" == "Managed" ]] \
        || die "OpenShift AI KServe is ${KSERVE_STATE:-unavailable}; expected Managed on DataScienceCluster ${OPENSHIFT_AI_DSC}."
    oc get crd inferenceservices.serving.kserve.io >/dev/null 2>&1 \
        || die "OpenShift AI KServe CRD inferenceservices.serving.kserve.io is not installed."

    MLFLOW_OPERATOR_STATE="$(oc get datasciencecluster "${OPENSHIFT_AI_DSC}" \
        -o jsonpath='{.spec.components.mlflowoperator.managementState}' 2>/dev/null || true)"
    [[ "${MLFLOW_OPERATOR_STATE}" == "Managed" ]] \
        || die "OpenShift AI MLflow operator is ${MLFLOW_OPERATOR_STATE:-unavailable}; expected Managed on DataScienceCluster ${OPENSHIFT_AI_DSC}."
    oc get crd mlflows.mlflow.opendatahub.io >/dev/null 2>&1 \
        || die "OpenShift AI MLflow CRD mlflows.mlflow.opendatahub.io is not installed."
    oc get clusterrole "${MLFLOW_INTEGRATION_CLUSTER_ROLE}" >/dev/null 2>&1 \
        || die "OpenShift AI MLflow integration ClusterRole not found: ${MLFLOW_INTEGRATION_CLUSTER_ROLE}"

    oc get storageclass "${S4_STORAGE_CLASS}" >/dev/null 2>&1 \
        || die "StorageClass not found: ${S4_STORAGE_CLASS}"
    oc get storageclass "${MLFLOW_STORAGE_CLASS}" >/dev/null 2>&1 \
        || die "StorageClass not found for MLflow: ${MLFLOW_STORAGE_CLASS}"
    success "OpenShift AI KServe and MLflow operators are ready."
}

bootstrap_install_stack_chart() {
    STACK_CHART_PATH="${REPO_ROOT}/deploy/helm/zenml-stack"
    [[ -d "${STACK_CHART_PATH}" ]] || die "Helm chart not found: ${STACK_CHART_PATH}"

    section "Installing workload infrastructure with Helm"
    info "Chart:     ${STACK_CHART_PATH}"
    info "Release:   ${ZENML_STACK_RELEASE}"
    info "Namespace: ${ZENML_WORKLOAD_NAMESPACE}"

    # shellcheck source=lib/helm/secrets.sh
    source "${SCRIPT_DIR}/lib/helm/secrets.sh"

    local -a helm_args=(
        upgrade --install "${ZENML_STACK_RELEASE}" "${STACK_CHART_PATH}"
        --namespace "${ZENML_WORKLOAD_NAMESPACE}"
        --create-namespace
        --set "orchestrator.serviceAccountName=${ZENML_ORCHESTRATOR_SA}"
        --set "s4.enabled=true"
        --set "s4.fullnameOverride=s4"
        --set "s4.image.repository=${S4_IMAGE_REPOSITORY}"
        --set "s4.image.tag=${S4_IMAGE_TAG}"
        --set "s4.s3.accessKeyId=${S4_ACCESS_KEY_ID}"
        --set "s4.auth.enabled=true"
        --set "s4.auth.username=${S4_UI_AUTH_USERNAME}"
        --set "s4.route.enabled=true"
        --set "s4.route.s3Api.enabled=true"
        --set "s4.storage.data.storageClass=${S4_STORAGE_CLASS}"
        --set "s4.storage.data.size=${S4_STORAGE_SIZE}"
        --set "s4Buckets.create=true"
        --set "s4Buckets.names[0]=${S4_BUCKET}"
        --set "jobImages.cli=${JOB_IMAGE_CLI}"
        --set "jobImages.python=${JOB_IMAGE_PYTHON}"
        --set "kserve.roleName=${MODEL_SERVING_ROLE}"
        --set "kserve.roleBindingName=${MODEL_SERVING_ROLE_BINDING}"
        --set "mlflow.instance=${MLFLOW_INSTANCE}"
        --set "mlflow.storageClass=${MLFLOW_STORAGE_CLASS}"
        --set "mlflow.storageSize=${MLFLOW_STORAGE_SIZE}"
        --set "mlflow.integrationClusterRole=${MLFLOW_INTEGRATION_CLUSTER_ROLE}"
        --set "mlflow.roleBindingName=${MLFLOW_ROLE_BINDING}"
        --set "registry.pullSecretName=${ZENML_REGISTRY_PULL_SECRET}"
        --set "registry.imageStreamName=zenml"
    )

    helm_ensure_secrets_file "${STACK_CHART_PATH}"
    helm_args+=(--values "$(helm_secrets_file "${STACK_CHART_PATH}")")

    if [[ -n "${S4_SECRET_ACCESS_KEY}" ]]; then
        helm_args+=(--set-string "s4.s3.secretAccessKey=${S4_SECRET_ACCESS_KEY}")
    fi
    if [[ -n "${S4_UI_AUTH_PASSWORD}" ]]; then
        helm_args+=(--set-string "s4.auth.password=${S4_UI_AUTH_PASSWORD}")
    fi

    # Helm --wait confirms the release as a whole. Sequenced checks after
    # install still enforce SA/RBAC, KServe, MLflow, S4, then the bucket Job.
    run_logged helm "${helm_args[@]}" --wait --timeout 10m
    success "Helm release ${ZENML_STACK_RELEASE} is installed."
}

bootstrap_verify_workload_identity() {
    section "Verifying the dedicated workload project and identity"

    oc get project "${ZENML_WORKLOAD_NAMESPACE}" >/dev/null 2>&1 \
        || die "Workload project was not found: ${ZENML_WORKLOAD_NAMESPACE}"
    oc get serviceaccount "${ZENML_ORCHESTRATOR_SA}" -n "${ZENML_WORKLOAD_NAMESPACE}" >/dev/null 2>&1 \
        || die "Orchestrator service account was not found: ${ZENML_ORCHESTRATOR_SA}"

    [[ "$(oc auth can-i create pods --as="system:serviceaccount:${ZENML_WORKLOAD_NAMESPACE}:${ZENML_ORCHESTRATOR_SA}" -n "${ZENML_WORKLOAD_NAMESPACE}")" == "yes" ]] \
        || die "${ZENML_ORCHESTRATOR_SA} cannot create pods in ${ZENML_WORKLOAD_NAMESPACE}."
    [[ "$(oc auth can-i create jobs --as="system:serviceaccount:${ZENML_WORKLOAD_NAMESPACE}:${ZENML_ORCHESTRATOR_SA}" -n "${ZENML_WORKLOAD_NAMESPACE}")" == "yes" ]] \
        || die "${ZENML_ORCHESTRATOR_SA} cannot create jobs in ${ZENML_WORKLOAD_NAMESPACE}."
    [[ "$(oc auth can-i update imagestreams/layers --as="system:serviceaccount:${ZENML_WORKLOAD_NAMESPACE}:${ZENML_ORCHESTRATOR_SA}" -n "${ZENML_WORKLOAD_NAMESPACE}")" == "yes" ]] \
        || die "${ZENML_ORCHESTRATOR_SA} cannot push images in ${ZENML_WORKLOAD_NAMESPACE}."
    success "Orchestrator service account can create workloads and push project images."
}

bootstrap_wait_for_kserve() {
    section "Verifying OpenShift AI KServe model deployment"

    oc get role "${MODEL_SERVING_ROLE}" -n "${ZENML_WORKLOAD_NAMESPACE}" >/dev/null 2>&1 \
        || die "KServe Role was not found: ${MODEL_SERVING_ROLE}"
    oc get rolebinding "${MODEL_SERVING_ROLE_BINDING}" -n "${ZENML_WORKLOAD_NAMESPACE}" >/dev/null 2>&1 \
        || die "KServe RoleBinding was not found: ${MODEL_SERVING_ROLE_BINDING}"

    [[ "$(oc auth can-i create inferenceservices.serving.kserve.io \
        --as="system:serviceaccount:${ZENML_WORKLOAD_NAMESPACE}:${ZENML_ORCHESTRATOR_SA}" \
        -n "${ZENML_WORKLOAD_NAMESPACE}")" == "yes" ]] \
        || die "${ZENML_ORCHESTRATOR_SA} cannot create KServe InferenceServices in ${ZENML_WORKLOAD_NAMESPACE}."
    [[ "$(oc auth can-i create routes.route.openshift.io \
        --as="system:serviceaccount:${ZENML_WORKLOAD_NAMESPACE}:${ZENML_ORCHESTRATOR_SA}" \
        -n "${ZENML_WORKLOAD_NAMESPACE}")" == "yes" ]] \
        || die "${ZENML_ORCHESTRATOR_SA} cannot create the search UI Route in ${ZENML_WORKLOAD_NAMESPACE}."
    success "OpenShift AI KServe is managed and the orchestrator can deploy InferenceServices and Routes."
}

bootstrap_wait_for_mlflow() {
    section "Provisioning the shared OpenShift AI MLflow instance"

    run_logged oc wait --for=condition=Available "mlflow/${MLFLOW_INSTANCE}" --timeout=300s
    run_logged oc rollout status "deployment/${MLFLOW_INSTANCE}" \
        -n "${OPENSHIFT_AI_APPLICATIONS_NAMESPACE}" \
        --timeout=180s
    MLFLOW_URL="$(oc get mlflow "${MLFLOW_INSTANCE}" -o jsonpath='{.status.url}')"
    [[ "${MLFLOW_URL}" == https://* ]] \
        || die "MLflow external URL is missing or invalid: ${MLFLOW_URL:-unavailable}"

    oc get rolebinding "${MLFLOW_ROLE_BINDING}" -n "${ZENML_WORKLOAD_NAMESPACE}" >/dev/null 2>&1 \
        || die "MLflow integration RoleBinding was not found: ${MLFLOW_ROLE_BINDING}"
    success "MLflow is available at ${MLFLOW_URL}; workload integration RBAC is configured."
}

bootstrap_wait_for_s4() {
    section "Provisioning persistent S4"

    run_logged oc rollout status deployment/s4 \
        -n "${ZENML_WORKLOAD_NAMESPACE}" \
        --timeout=180s

    S4_UI_ROUTE_HOST="$(oc get route "${S4_UI_ROUTE_NAME}" -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{.spec.host}')"
    [[ -n "${S4_UI_ROUTE_HOST}" ]] || die "S4 UI Route was not found: ${S4_UI_ROUTE_NAME}"
    S4_UI_ENDPOINT="https://${S4_UI_ROUTE_HOST}"
    curl --fail --silent --show-error --max-time 15 \
        "${S4_UI_ENDPOINT}/api" >/dev/null \
        || die "S4 UI Route health check failed: ${S4_UI_ENDPOINT}/api"
    success "S4 UI is healthy at ${S4_UI_ENDPOINT}."

    S4_API_ROUTE_HOST="$(oc get route "${S4_API_ROUTE_NAME}" -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{.spec.host}')"
    [[ -n "${S4_API_ROUTE_HOST}" ]] || die "S4 S3 API Route was not found: ${S4_API_ROUTE_NAME}"
    S4_ENDPOINT="https://${S4_API_ROUTE_HOST}"
    success "S4 S3 API Route is admitted at ${S4_ENDPOINT}."
}

bootstrap_wait_for_s4_bucket() {
    section "Creating and smoke-testing the artifact bucket"

    run_logged oc wait --for=condition=complete job/s4-bootstrap \
        -n "${ZENML_WORKLOAD_NAMESPACE}" \
        --timeout=180s
    oc logs job/s4-bootstrap -n "${ZENML_WORKLOAD_NAMESPACE}" --tail=40
    success "Bucket ${S4_BUCKET} passed the S4 write/read smoke test."
}
