#!/usr/bin/env bash

validate_server_print_summary() {
    section "Validation summary"

    echo "    OpenShift project:  ${ZENML_NAMESPACE}"
    echo "    Helm release:       ${ZENML_RELEASE}"
    echo "    Helm revision:      ${HELM_REVISION}"
    echo "    Helm status:        ${HELM_STATUS}"
    echo "    ZenML URL:          ${ZENML_URL}"
    echo "    Database URL:       ${ZENML_DATABASE_URL}"
    echo "    Database ClusterIP: ${MYSQL_SERVICE_IP}"
    echo "    Database version:   ${MYSQL_VERSION:-unavailable}"
    echo "    PVCs:               ${PVC_SUMMARY:-none found}"
    echo

    if [[ "${FAILURES}" -eq 0 ]]; then
        log_info "Validation result: PASS — ZenML server infrastructure is healthy."
        echo "    RESULT: PASS — ZenML server infrastructure is healthy."
        exit 0
    fi

    log_error "Validation result: FAIL — ${FAILURES} validation check(s) failed."
    echo "    RESULT: FAIL — ${FAILURES} validation check(s) failed." >&2
    exit 1
}
