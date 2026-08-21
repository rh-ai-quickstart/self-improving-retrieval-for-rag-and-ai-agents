#!/usr/bin/env bash

validate_server_check_database() {
    section "Checking the persistent MySQL database"

    MYSQL_VERSION="unavailable"
    MYSQL_SERVICE_IP="unavailable"
    MYSQL_POD=""

    if [[ "${PROJECT_EXISTS}" == "true" ]] && oc get deploymentconfig "${ZENML_DB_SERVICE}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1; then
        MYSQL_AVAILABLE="$(oc get deploymentconfig "${ZENML_DB_SERVICE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{.status.availableReplicas}')"
        if [[ "${MYSQL_AVAILABLE:-0}" -ge 1 ]]; then
            pass "MySQL DeploymentConfig is available."
        else
            fail "MySQL DeploymentConfig has no available replicas."
        fi
    else
        fail "MySQL DeploymentConfig was not found: ${ZENML_DB_SERVICE}"
    fi

    MYSQL_POD="$(oc get pods \
        -n "${ZENML_NAMESPACE}" \
        -l "name=${ZENML_DB_SERVICE}" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "${MYSQL_POD}" ]]; then
        MYSQL_READY="$(oc get pod "${MYSQL_POD}" -n "${ZENML_NAMESPACE}" -o jsonpath='{.status.containerStatuses[0].ready}')"
        if [[ "${MYSQL_READY}" == "true" ]]; then
            pass "MySQL pod is ready: ${MYSQL_POD}"
        else
            fail "MySQL pod is running but not ready: ${MYSQL_POD}"
        fi
        MYSQL_VERSION="$(oc exec -n "${ZENML_NAMESPACE}" "${MYSQL_POD}" -- mysql --version 2>/dev/null || true)"
        info "Detected database version: ${MYSQL_VERSION:-unavailable}"
    else
        fail "No running MySQL pod was found for ${ZENML_DB_SERVICE}."
    fi

    if oc get service "${ZENML_DB_SERVICE}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1; then
        MYSQL_SERVICE_IP="$(oc get service "${ZENML_DB_SERVICE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{.spec.clusterIP}')"
        MYSQL_ENDPOINTS="$(oc get endpoints "${ZENML_DB_SERVICE}" -n "${ZENML_NAMESPACE}" -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{" "}{end}' 2>/dev/null || true)"
        pass "MySQL Service exists: ${ZENML_DB_SERVICE} (${MYSQL_SERVICE_IP}:3306)"
        if [[ -n "${MYSQL_ENDPOINTS}" ]]; then
            pass "MySQL Service has ready endpoints: ${MYSQL_ENDPOINTS}"
        else
            fail "MySQL Service has no ready endpoints."
        fi
    else
        fail "MySQL Service was not found: ${ZENML_DB_SERVICE}"
    fi

    if oc get secret "${ZENML_DB_PASSWORD_SECRET}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1; then
        pass "ZenML database-password Secret exists: ${ZENML_DB_PASSWORD_SECRET}"
    else
        fail "ZenML database-password Secret was not found: ${ZENML_DB_PASSWORD_SECRET}"
    fi

    PVC_SUMMARY="$(oc get pvc -n "${ZENML_NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.phase}{"("}{.spec.resources.requests.storage}{") "}{end}' 2>/dev/null || true)"
    if [[ -n "${PVC_SUMMARY}" ]]; then
        info "PersistentVolumeClaims: ${PVC_SUMMARY}"
        UNBOUND_PVCS="$(oc get pvc -n "${ZENML_NAMESPACE}" --no-headers 2>/dev/null | awk '$2 != "Bound" {print $1}' | xargs)"
        if [[ -z "${UNBOUND_PVCS}" ]]; then
            pass "All PersistentVolumeClaims are bound."
        else
            fail "Unbound PersistentVolumeClaims: ${UNBOUND_PVCS}"
        fi
    else
        fail "No PersistentVolumeClaims were found in ${ZENML_NAMESPACE}."
    fi
}
