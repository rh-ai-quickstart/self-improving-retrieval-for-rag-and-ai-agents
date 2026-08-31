#!/usr/bin/env bash

bootstrap_setup_registry() {
    section "Exposing and authenticating to the OpenShift image registry"
    REGISTRY_STATE="$(oc get configs.imageregistry.operator.openshift.io cluster -o jsonpath='{.spec.managementState}')"
    [[ "${REGISTRY_STATE}" == "Managed" ]] || die "OpenShift image registry managementState is ${REGISTRY_STATE}, expected Managed."
    oc patch configs.imageregistry.operator.openshift.io/cluster \
        --type=merge \
        --patch '{"spec":{"defaultRoute":true}}' >/dev/null

    for attempt in {1..30}; do
        REGISTRY_ROUTE_ADMITTED="$(oc get route "${OPENSHIFT_REGISTRY_ROUTE}" \
            -n "${OPENSHIFT_REGISTRY_NAMESPACE}" \
            -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}' \
            2>/dev/null || true)"
        if [[ "${REGISTRY_ROUTE_ADMITTED}" == "True" ]]; then
            break
        fi
        [[ "${attempt}" -lt 30 ]] || die "OpenShift registry Route was not admitted."
        sleep 2
    done
    REGISTRY_HOST="$(oc get route "${OPENSHIFT_REGISTRY_ROUTE}" -n "${OPENSHIFT_REGISTRY_NAMESPACE}" -o jsonpath='{.spec.host}')"
    REGISTRY_URI="${REGISTRY_HOST}/${ZENML_WORKLOAD_NAMESPACE}"

    REGISTRY_TOKEN="$(oc create token "${ZENML_ORCHESTRATOR_SA}" \
        -n "${ZENML_WORKLOAD_NAMESPACE}" \
        --duration="${ZENML_REGISTRY_TOKEN_DURATION}")"
    printf '%s' "${REGISTRY_TOKEN}" \
        | docker login "${REGISTRY_HOST}" \
            --username "${OPENSHIFT_REGISTRY_USERNAME}" \
            --password-stdin >/dev/null
    success "Docker authenticated to ${REGISTRY_HOST} as ${OPENSHIFT_REGISTRY_USERNAME}."

    oc create secret docker-registry "${ZENML_REGISTRY_PULL_SECRET}" \
        -n "${ZENML_WORKLOAD_NAMESPACE}" \
        --docker-server="${REGISTRY_HOST}" \
        --docker-username="${OPENSHIFT_REGISTRY_USERNAME}" \
        --docker-password="${REGISTRY_TOKEN}" \
        --dry-run=client \
        -o yaml \
        | oc apply -f - >/dev/null
    unset REGISTRY_TOKEN
    oc label secret "${ZENML_REGISTRY_PULL_SECRET}" \
        -n "${ZENML_WORKLOAD_NAMESPACE}" \
        app.kubernetes.io/part-of=zenml-stack-bootstrap \
        --overwrite >/dev/null
    oc secrets link "${ZENML_ORCHESTRATOR_SA}" "${ZENML_REGISTRY_PULL_SECRET}" \
        -n "${ZENML_WORKLOAD_NAMESPACE}" \
        --for=pull >/dev/null

    oc create imagestream zenml \
        -n "${ZENML_WORKLOAD_NAMESPACE}" \
        --dry-run=client \
        -o yaml \
        | oc apply -f - >/dev/null
    oc label imagestream zenml \
        -n "${ZENML_WORKLOAD_NAMESPACE}" \
        app.kubernetes.io/part-of=zenml-stack-bootstrap \
        --overwrite >/dev/null
    success "Registry repository and renewable pull credentials are configured."
}
