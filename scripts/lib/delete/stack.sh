#!/usr/bin/env bash

delete_stack_load_and_show() {
    local config_file="$1"

    section "Loading workload-stack deletion configuration"
    load_stack_config "${config_file}"
    require_command oc
    require_command zenml

    oc whoami >/dev/null 2>&1 || die "The oc CLI is not authenticated to OpenShift."
    zenml status >/dev/null 2>&1 || die "The ZenML CLI is not authenticated; registrations must be removed before the workload project."

    OPENSHIFT_USER="$(oc whoami)"
    OPENSHIFT_SERVER="$(oc whoami --show-server)"
    info "OpenShift user:    ${OPENSHIFT_USER}"
    info "OpenShift cluster: ${OPENSHIFT_SERVER}"
    info "Workload project:  ${ZENML_WORKLOAD_NAMESPACE}"

    section "Resources selected for deletion"
    echo "    ZenML registrations:"
    echo "      stack/${ZENML_STACK}"
    echo "      experiment-tracker/${ZENML_EXPERIMENT_TRACKER}"
    echo "      image-builder/${ZENML_IMAGE_BUILDER}"
    echo "      container-registry/${ZENML_CONTAINER_REGISTRY}"
    echo "      artifact-store/${ZENML_ARTIFACT_STORE}"
    echo "      orchestrator/${ZENML_ORCHESTRATOR}"
    echo "      service-connector/${ZENML_K8S_CONNECTOR}"
    echo "      secret/${ZENML_ARTIFACT_SECRET}"
    echo
    echo "    Dedicated OpenShift project and everything inside it:"
    echo "      project/${ZENML_WORKLOAD_NAMESPACE}"
    echo "      inferenceservice/${MODEL_SERVING_NAME}"
    echo
    echo "    Retained shared cluster resources:"
    echo "      route/${OPENSHIFT_REGISTRY_NAMESPACE}/${OPENSHIFT_REGISTRY_ROUTE}"
    echo "      mlflow/${MLFLOW_INSTANCE}"
    echo
    echo "    The ZenML server project is not touched by this command."

    if oc get project "${ZENML_WORKLOAD_NAMESPACE}" >/dev/null 2>&1; then
        echo
        echo "Current workload resources:"
        oc get deployment,pod,service,pvc,route,job,imagestream,inferenceservice \
            -n "${ZENML_WORKLOAD_NAMESPACE}" \
            --ignore-not-found 2>/dev/null || true
    else
        info "Project ${ZENML_WORKLOAD_NAMESPACE} is already absent."
    fi
}

delete_stack_confirm() {
    section "Confirming destructive deletion"
    echo "    WARNING: deleting the project permanently removes MinIO artifacts, images, and its PVC."
    echo

    if [[ -z "${ZENML_STACK_DELETE_CONFIRM}" ]]; then
        if [[ ! -t 0 ]]; then
            die "Interactive confirmation is unavailable. Set ZENML_STACK_DELETE_CONFIRM=${ZENML_WORKLOAD_NAMESPACE} to confirm explicitly."
        fi
        read -r -p "Type '${ZENML_WORKLOAD_NAMESPACE}' to delete the workload stack: " ZENML_STACK_DELETE_CONFIRM
    fi

    if [[ "${ZENML_STACK_DELETE_CONFIRM}" != "${ZENML_WORKLOAD_NAMESPACE}" ]]; then
        die "Confirmation did not match ${ZENML_WORKLOAD_NAMESPACE}; nothing was deleted."
    fi
    success "Deletion confirmed for ${ZENML_WORKLOAD_NAMESPACE}."
}

delete_stack_execute() {
    section "Deleting ZenML registrations"
    if zenml stack describe "${ZENML_STACK}" >/dev/null 2>&1; then
        zenml stack describe "${ZENML_DELETE_FALLBACK_STACK}" >/dev/null 2>&1 \
            || die "Cannot delete stack ${ZENML_STACK}: fallback stack ${ZENML_DELETE_FALLBACK_STACK} is unavailable."
        zenml stack set "${ZENML_DELETE_FALLBACK_STACK}" >/dev/null
        success "Selected fallback stack before deletion: ${ZENML_DELETE_FALLBACK_STACK}"
        zenml stack delete "${ZENML_STACK}" -y >/dev/null
        success "Deleted stack: ${ZENML_STACK}"
    else
        info "Stack ${ZENML_STACK} is not present; skipping."
    fi

    delete_component_if_present image-builder "${ZENML_IMAGE_BUILDER}" "image builder"
    delete_component_if_present container-registry "${ZENML_CONTAINER_REGISTRY}" "container registry"
    delete_component_if_present artifact-store "${ZENML_ARTIFACT_STORE}" "artifact store"
    delete_component_if_present experiment-tracker "${ZENML_EXPERIMENT_TRACKER}" "experiment tracker"
    delete_component_if_present orchestrator "${ZENML_ORCHESTRATOR}" "orchestrator"

    if zenml service-connector describe "${ZENML_K8S_CONNECTOR}" >/dev/null 2>&1; then
        zenml service-connector delete "${ZENML_K8S_CONNECTOR}" >/dev/null
        success "Deleted service connector: ${ZENML_K8S_CONNECTOR}"
    else
        info "Service connector ${ZENML_K8S_CONNECTOR} is not present; skipping."
    fi

    if ZENML_ARTIFACT_SECRET_ID="$(zenml_public_secret_id "${ZENML_ARTIFACT_SECRET}" 2>/dev/null)"; then
        zenml secret delete "${ZENML_ARTIFACT_SECRET_ID}" -y >/dev/null
        success "Deleted ZenML Secret: ${ZENML_ARTIFACT_SECRET}"
    else
        info "ZenML Secret ${ZENML_ARTIFACT_SECRET} is not present; skipping."
    fi

    section "Deleting the workload Helm release and project"
    ZENML_STACK_RELEASE="${ZENML_STACK_RELEASE:-zenml-stack}"
    if helm status "${ZENML_STACK_RELEASE}" -n "${ZENML_WORKLOAD_NAMESPACE}" >/dev/null 2>&1; then
        helm uninstall "${ZENML_STACK_RELEASE}" \
            -n "${ZENML_WORKLOAD_NAMESPACE}" \
            --wait \
            --timeout 5m
        success "Helm release ${ZENML_STACK_RELEASE} was uninstalled."
    else
        info "Helm release ${ZENML_STACK_RELEASE} is not present; continuing with project deletion."
    fi

    if oc get project "${ZENML_WORKLOAD_NAMESPACE}" >/dev/null 2>&1; then
        oc delete project "${ZENML_WORKLOAD_NAMESPACE}" --wait=true --timeout=5m
        success "Deleted project ${ZENML_WORKLOAD_NAMESPACE} and its persistent workload data."
    else
        info "Project ${ZENML_WORKLOAD_NAMESPACE} is already absent."
    fi
}

delete_stack_print_summary() {
    section "Workload-stack teardown completed"
    echo "    Workload project:       ${ZENML_WORKLOAD_NAMESPACE} (removed)"
    echo "    ZenML stack:            ${ZENML_STACK} (removed)"
    echo "    Registry default Route: ${OPENSHIFT_REGISTRY_ROUTE} (retained)"
    echo "    Shared MLflow instance: ${MLFLOW_INSTANCE} (retained)"
    echo "    ZenML server project:   retained"
    echo
    echo "To recreate the remote stack:"
    echo "    just bootstrap-stack"
}
