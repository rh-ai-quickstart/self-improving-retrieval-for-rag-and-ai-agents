#!/usr/bin/env bash

validate_model_check_inference() {
    section "Checking the OpenShift AI KServe deployment"
    READY="$(oc get inferenceservice "${MODEL_SERVING_NAME}" \
        -n "${ZENML_WORKLOAD_NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
        2>/dev/null || true)"
    [[ "${READY}" == "True" ]] \
        || die "InferenceService ${ZENML_WORKLOAD_NAMESPACE}/${MODEL_SERVING_NAME} is missing or not Ready."

    MODEL_ID="$(oc get inferenceservice "${MODEL_SERVING_NAME}" \
        -n "${ZENML_WORKLOAD_NAMESPACE}" \
        -o jsonpath='{.spec.predictor.containers[0].env[?(@.name=="MODEL_ID")].value}')"
    [[ -n "${MODEL_ID}" ]] \
        || die "InferenceService ${MODEL_SERVING_NAME} does not declare MODEL_ID."

    PREDICTOR_POD="$(oc get pods \
        -n "${ZENML_WORKLOAD_NAMESPACE}" \
        -l "serving.kserve.io/inferenceservice=${MODEL_SERVING_NAME}" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [[ -n "${PREDICTOR_POD}" ]] \
        || die "No running predictor pod was found for InferenceService ${MODEL_SERVING_NAME}."

    PREDICTOR_PORT="$(oc get pod "${PREDICTOR_POD}" \
        -n "${ZENML_WORKLOAD_NAMESPACE}" \
        -o jsonpath='{.spec.containers[?(@.name=="kserve-container")].ports[?(@.name=="http1")].containerPort}' \
        2>/dev/null || true)"
    [[ "${PREDICTOR_PORT}" =~ ^[1-9][0-9]*$ ]] \
        || die "Predictor pod ${PREDICTOR_POD} does not declare a valid kserve-container/http1 port."

    ROUTE_HOST="$(oc get route "${MODEL_SERVING_ROUTE}" \
        -n "${ZENML_WORKLOAD_NAMESPACE}" \
        -o jsonpath='{.status.ingress[0].host}' \
        2>/dev/null || true)"
    [[ -n "${ROUTE_HOST}" ]] \
        || die "Search UI Route ${ZENML_WORKLOAD_NAMESPACE}/${MODEL_SERVING_ROUTE} is missing or not admitted."
    ROUTE_URL="https://${ROUTE_HOST}"

    success "InferenceService is Ready with model ${MODEL_ID}."
    success "Search UI Route is admitted at ${ROUTE_URL}."
}
