#!/usr/bin/env bash

bootstrap_register_zenml_components() {
    section "Registering the Kubernetes connector and orchestrator"
    K8S_SERVER="${OPENSHIFT_SERVER}"
    if [[ -z "${ZENML_K8S_CLUSTER_NAME}" ]]; then
        ZENML_K8S_CLUSTER_NAME="$(oc config view --minify -o jsonpath='{.contexts[0].context.cluster}')"
    fi
    K8S_CA_DATA="$(oc config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
    [[ -n "${K8S_CA_DATA}" ]] || die "The current kubeconfig does not contain certificate-authority-data."
    K8S_CA="$(printf '%s' "${K8S_CA_DATA}" | python3 -c '
import base64
import sys
certificate = base64.b64decode(sys.stdin.buffer.read())
print(base64.urlsafe_b64encode(certificate).decode())
')"
    K8S_TOKEN="$(oc create token "${ZENML_ORCHESTRATOR_SA}" \
        -n "${ZENML_WORKLOAD_NAMESPACE}" \
        --duration="${ZENML_K8S_TOKEN_DURATION}")"

    if zenml service-connector describe "${ZENML_K8S_CONNECTOR}" >/dev/null 2>&1; then
        zenml service-connector update "${ZENML_K8S_CONNECTOR}" \
            --cluster_name="${ZENML_K8S_CLUSTER_NAME}" \
            --token="${K8S_TOKEN}" \
            --server="${K8S_SERVER}" \
            --certificate_authority="${K8S_CA}" >/dev/null
    else
        zenml service-connector register "${ZENML_K8S_CONNECTOR}" \
            --type=kubernetes \
            --auth-method=token \
            --cluster_name="${ZENML_K8S_CLUSTER_NAME}" \
            --token="${K8S_TOKEN}" \
            --server="${K8S_SERVER}" \
            --certificate_authority="${K8S_CA}" \
            --resource-type=kubernetes-cluster >/dev/null
    fi
    unset K8S_TOKEN K8S_CA K8S_CA_DATA
    zenml service-connector verify "${ZENML_K8S_CONNECTOR}" >/dev/null
    success "Kubernetes service connector is verified."

    if component_exists orchestrator "${ZENML_ORCHESTRATOR}"; then
        zenml orchestrator update "${ZENML_ORCHESTRATOR}" \
            --kubernetes_namespace="${ZENML_WORKLOAD_NAMESPACE}" \
            --service_account_name="${ZENML_ORCHESTRATOR_SA}" \
            --step_pod_service_account_name="${ZENML_ORCHESTRATOR_SA}" \
            --skip_owner_references=true >/dev/null
    else
        zenml orchestrator register "${ZENML_ORCHESTRATOR}" \
            --flavor=kubernetes \
            --kubernetes_namespace="${ZENML_WORKLOAD_NAMESPACE}" \
            --service_account_name="${ZENML_ORCHESTRATOR_SA}" \
            --step_pod_service_account_name="${ZENML_ORCHESTRATOR_SA}" \
            --skip_owner_references=true \
            --connector="${ZENML_K8S_CONNECTOR}" >/dev/null
    fi
    success "Kubernetes orchestrator is registered with OpenShift owner-reference compatibility."

    section "Registering the artifact store, registry, image builder, and stack"
    ZENML_SECRET_FILE="$(mktemp)"
    cleanup_files+=("${ZENML_SECRET_FILE}")
    chmod 600 "${ZENML_SECRET_FILE}"
    oc get secret "${MINIO_SECRET_NAME}" -n "${ZENML_WORKLOAD_NAMESPACE}" -o json \
        | python3 -c '
import base64
import json
import sys
secret = json.load(sys.stdin)["data"]
values = {
    "access_key_id": base64.b64decode(secret["MINIO_ROOT_USER"]).decode(),
    "secret_access_key": base64.b64decode(secret["MINIO_ROOT_PASSWORD"]).decode(),
}
json.dump(values, sys.stdout)
' > "${ZENML_SECRET_FILE}"

    if ZENML_ARTIFACT_SECRET_ID="$(zenml_public_secret_id "${ZENML_ARTIFACT_SECRET}" 2>/dev/null)"; then
        zenml secret update "${ZENML_ARTIFACT_SECRET_ID}" --values="@${ZENML_SECRET_FILE}" >/dev/null
    else
        zenml secret create "${ZENML_ARTIFACT_SECRET}" --values="@${ZENML_SECRET_FILE}" >/dev/null
    fi

    MINIO_CLIENT_KWARGS="$(printf '{"endpoint_url":"%s","region_name":"us-east-1"}' "${MINIO_ENDPOINT}")"
    if component_exists artifact-store "${ZENML_ARTIFACT_STORE}"; then
        zenml artifact-store update "${ZENML_ARTIFACT_STORE}" \
            --path="s3://${MINIO_BUCKET}" \
            --authentication_secret="${ZENML_ARTIFACT_SECRET}" \
            --client_kwargs="${MINIO_CLIENT_KWARGS}" >/dev/null
    else
        zenml artifact-store register "${ZENML_ARTIFACT_STORE}" \
            --flavor=s3 \
            --path="s3://${MINIO_BUCKET}" \
            --authentication_secret="${ZENML_ARTIFACT_SECRET}" \
            --client_kwargs="${MINIO_CLIENT_KWARGS}" >/dev/null
    fi

    if component_exists container-registry "${ZENML_CONTAINER_REGISTRY}"; then
        zenml container-registry update "${ZENML_CONTAINER_REGISTRY}" --uri="${REGISTRY_URI}" >/dev/null
    else
        zenml container-registry register "${ZENML_CONTAINER_REGISTRY}" \
            --flavor=default \
            --uri="${REGISTRY_URI}" >/dev/null
    fi

    if component_exists image-builder "${ZENML_IMAGE_BUILDER}"; then
        IMAGE_BUILDER_FLAVOR="$("${ZENML_PYTHON}" - "${ZENML_IMAGE_BUILDER}" <<'PY'
import sys
from zenml.client import Client
from zenml.enums import StackComponentType
print(Client().get_stack_component(StackComponentType.IMAGE_BUILDER, sys.argv[1]).flavor_name)
PY
)"
        [[ "${IMAGE_BUILDER_FLAVOR}" == "local" ]] \
            || die "Image builder ${ZENML_IMAGE_BUILDER} uses flavor ${IMAGE_BUILDER_FLAVOR}; expected local."
    else
        zenml image-builder register "${ZENML_IMAGE_BUILDER}" --flavor=local >/dev/null
    fi

    MLFLOW_TOKEN="$(oc create token "${ZENML_ORCHESTRATOR_SA}" \
        -n "${ZENML_WORKLOAD_NAMESPACE}" \
        --duration="${ZENML_MLFLOW_TOKEN_DURATION}")"
    if component_exists experiment-tracker "${ZENML_EXPERIMENT_TRACKER}"; then
        zenml experiment-tracker update "${ZENML_EXPERIMENT_TRACKER}" \
            --tracking_uri="${MLFLOW_URL}" \
            --tracking_token="${MLFLOW_TOKEN}" \
            --env="MLFLOW_WORKSPACE=${ZENML_WORKLOAD_NAMESPACE}" >/dev/null
    else
        zenml experiment-tracker register "${ZENML_EXPERIMENT_TRACKER}" \
            --flavor=mlflow \
            --tracking_uri="${MLFLOW_URL}" \
            --tracking_token="${MLFLOW_TOKEN}" \
            --env="MLFLOW_WORKSPACE=${ZENML_WORKLOAD_NAMESPACE}" >/dev/null
    fi
    unset MLFLOW_TOKEN

    if zenml stack describe "${ZENML_STACK}" >/dev/null 2>&1; then
        zenml stack update "${ZENML_STACK}" \
            -o "${ZENML_ORCHESTRATOR}" \
            -a "${ZENML_ARTIFACT_STORE}" \
            -c "${ZENML_CONTAINER_REGISTRY}" \
            -i "${ZENML_IMAGE_BUILDER}" \
            -e "${ZENML_EXPERIMENT_TRACKER}" >/dev/null
    else
        zenml stack register "${ZENML_STACK}" \
            -o "${ZENML_ORCHESTRATOR}" \
            -a "${ZENML_ARTIFACT_STORE}" \
            -c "${ZENML_CONTAINER_REGISTRY}" \
            -i "${ZENML_IMAGE_BUILDER}" \
            -e "${ZENML_EXPERIMENT_TRACKER}" \
            --set >/dev/null
    fi
    zenml stack set "${ZENML_STACK}" >/dev/null
}

bootstrap_print_summary() {
    section "ZenML remote stack bootstrap completed"
    echo "    OpenShift cluster:    ${OPENSHIFT_SERVER}"
    echo "    Workload project:    ${ZENML_WORKLOAD_NAMESPACE}"
    echo "    Orchestrator SA:     ${ZENML_ORCHESTRATOR_SA}"
    echo "    MinIO endpoint:      ${MINIO_ENDPOINT}"
    echo "    Artifact bucket:     s3://${MINIO_BUCKET}"
    echo "    MLflow URL:          ${MLFLOW_URL}"
    echo "    Registry URI:        ${REGISTRY_URI}"
    echo "    ZenML stack:         ${ZENML_STACK} (active)"
    echo "    Orchestrator:        ${ZENML_ORCHESTRATOR}"
    echo "    Artifact store:      ${ZENML_ARTIFACT_STORE}"
    echo "    Container registry:  ${ZENML_CONTAINER_REGISTRY}"
    echo "    Image builder:       ${ZENML_IMAGE_BUILDER}"
    echo "    Experiment tracker:  ${ZENML_EXPERIMENT_TRACKER}"
    echo "    KServe model:        ${MODEL_SERVING_NAME} (created by the pipeline)"
    echo
    echo "Next commands:"
    echo "    just validate-stack"
}
