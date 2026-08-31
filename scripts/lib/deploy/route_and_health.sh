#!/usr/bin/env bash

deploy_verify_route() {
    section "Verifying the OpenShift Route"

    oc get route "${ZENML_ROUTE}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1 \
        || die "OpenShift Route was not found: ${ZENML_ROUTE}"

    ROUTE_HOST="$(oc get route "${ZENML_ROUTE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{.spec.host}')"
    ZENML_URL="https://${ROUTE_HOST}"
    info "Route host: ${ROUTE_HOST}"
    info "ZenML URL:  ${ZENML_URL}"

    if [[ -n "${ZENML_ROUTE_HOST}" && "${ROUTE_HOST}" != "${ZENML_ROUTE_HOST}" ]]; then
        warn "Route hostname ${ROUTE_HOST} differs from requested hostname ${ZENML_ROUTE_HOST}."
    fi
}

deploy_check_health() {
    section "Checking ZenML health through the public Route"

    HEALTHY="false"
    for attempt in {1..30}; do
        info "Health check ${attempt}/30: ${ZENML_URL}/health"
        if curl --fail --silent --show-error "${ZENML_URL}/health" >/dev/null; then
            HEALTHY="true"
            break
        fi
        sleep 2
    done

    if [[ "${HEALTHY}" != "true" ]]; then
        echo
        echo "Useful diagnostics:"
        echo "  oc get pods -n ${ZENML_NAMESPACE}"
        echo "  oc get events -n ${ZENML_NAMESPACE} --sort-by='.lastTimestamp'"
        echo "  oc logs -n ${ZENML_NAMESPACE} deployment/${ZENML_RELEASE}"
        die "ZenML health check failed after 30 attempts."
    fi
    success "ZenML /health endpoint is responding."

    if curl --fail --silent --show-error "${ZENML_URL}/ready" >/dev/null; then
        success "ZenML /ready endpoint is responding."
    else
        warn "The /health endpoint passed, but /ready did not respond successfully."
    fi

    HELM_REVISION="$(helm status "${ZENML_RELEASE}" -n "${ZENML_NAMESPACE}" | awk '/^REVISION:/ {print $2}')"
    HELM_STATUS="$(helm status "${ZENML_RELEASE}" -n "${ZENML_NAMESPACE}" | awk '/^STATUS:/ {print $2}')"
}

deploy_print_summary() {
    section "Provisioned OpenShift resources"

    oc get deployment,statefulset,service,pvc,route \
        -n "${ZENML_NAMESPACE}" \
        -o wide

    section "ZenML deployment completed successfully"

    echo "    OpenShift cluster:    ${OPENSHIFT_SERVER}"
    echo "    OpenShift user:       ${OPENSHIFT_USER}"
    echo "    OpenShift project:    ${ZENML_NAMESPACE}"
    echo
    echo "    ZenML version:        ${ZENML_VERSION}"
    echo "    Helm release:         ${ZENML_RELEASE}"
    echo "    Helm revision:        ${HELM_REVISION:-unknown}"
    echo "    Helm status:          ${HELM_STATUS:-unknown}"
    echo "    ZenML Service:        ${ZENML_SERVICE}"
    echo "    ZenML Route:          ${ZENML_ROUTE}"
    echo "    ZenML URL:            ${ZENML_URL}"
    echo "    Health endpoint:      ${ZENML_URL}/health"
    echo "    Readiness endpoint:   ${ZENML_URL}/ready"
    echo
    echo "    Database URL:         ${ZENML_DATABASE_URL}"
    echo "    Database Service:     ${ZENML_DB_SERVICE}:3306"
    echo "    Database ClusterIP:   ${MYSQL_SERVICE_IP}"
    echo "    Database version:     ${MYSQL_VERSION}"
    echo "    Database storage:     ${ZENML_DB_STORAGE} requested"
    echo "    Database PVCs:        ${MYSQL_PVC:-none found}"
    echo "    Password Secret:      ${ZENML_DB_PASSWORD_SECRET}"
    echo
    echo "Remaining manual step:"
    echo "    Open ${ZENML_URL} in a browser and complete ZenML activation"
    echo "    to create the initial administrator account."
    echo
    echo "After activation, connect the local CLI with:"
    echo "    zenml login ${ZENML_URL}"
    echo "    zenml status"
    echo
}
