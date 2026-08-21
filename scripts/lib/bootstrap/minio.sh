#!/usr/bin/env bash

bootstrap_setup_minio() {
    local resource_template="$1"
    local bucket_job_template="$2"

    section "Provisioning persistent MinIO"
    oc get storageclass "${MINIO_STORAGE_CLASS}" >/dev/null 2>&1 \
        || die "StorageClass not found: ${MINIO_STORAGE_CLASS}"

    if oc get secret "${MINIO_SECRET_NAME}" -n "${ZENML_WORKLOAD_NAMESPACE}" >/dev/null 2>&1; then
        info "Preserving existing MinIO credentials in Secret ${MINIO_SECRET_NAME}."
    else
        MINIO_CREDENTIAL_DIR="$(mktemp -d)"
        cleanup_files+=("${MINIO_CREDENTIAL_DIR}")
        chmod 700 "${MINIO_CREDENTIAL_DIR}"
        if [[ -z "${MINIO_ROOT_PASSWORD}" ]]; then
            MINIO_ROOT_PASSWORD="$(openssl rand -hex 24)"
            info "Generated a random MinIO root password."
        fi
        printf '%s' "${MINIO_ROOT_USER}" > "${MINIO_CREDENTIAL_DIR}/MINIO_ROOT_USER"
        printf '%s' "${MINIO_ROOT_PASSWORD}" > "${MINIO_CREDENTIAL_DIR}/MINIO_ROOT_PASSWORD"
        chmod 600 "${MINIO_CREDENTIAL_DIR}"/*
        oc create secret generic "${MINIO_SECRET_NAME}" \
            -n "${ZENML_WORKLOAD_NAMESPACE}" \
            --from-file="MINIO_ROOT_USER=${MINIO_CREDENTIAL_DIR}/MINIO_ROOT_USER" \
            --from-file="MINIO_ROOT_PASSWORD=${MINIO_CREDENTIAL_DIR}/MINIO_ROOT_PASSWORD" \
            --dry-run=client \
            -o yaml \
            | oc apply -f - >/dev/null
    fi
    oc label secret "${MINIO_SECRET_NAME}" \
        -n "${ZENML_WORKLOAD_NAMESPACE}" \
        app.kubernetes.io/part-of=zenml-stack-bootstrap \
        --overwrite >/dev/null

    run_logged oc process -f "${resource_template}" \
        -p "MINIO_IMAGE=${MINIO_IMAGE}" \
        -p "MINIO_SECRET_NAME=${MINIO_SECRET_NAME}" \
        -p "MINIO_STORAGE_CLASS=${MINIO_STORAGE_CLASS}" \
        -p "MINIO_STORAGE_SIZE=${MINIO_STORAGE_SIZE}" \
        -p "MINIO_ROUTE_NAME=${MINIO_ROUTE_NAME}" \
        | run_logged oc apply -n "${ZENML_WORKLOAD_NAMESPACE}" -f - >/dev/null

    run_logged oc rollout status deployment/minio \
        -n "${ZENML_WORKLOAD_NAMESPACE}" \
        --timeout=180s
    MINIO_ROUTE_HOST="$(oc get route "${MINIO_ROUTE_NAME}" -n "${ZENML_WORKLOAD_NAMESPACE}" -o jsonpath='{.spec.host}')"
    MINIO_ENDPOINT="https://${MINIO_ROUTE_HOST}"
    curl --fail --silent --show-error --max-time 15 \
        "${MINIO_ENDPOINT}/minio/health/ready" >/dev/null \
        || die "MinIO Route health check failed: ${MINIO_ENDPOINT}"
    success "MinIO is healthy at ${MINIO_ENDPOINT}."

    section "Creating and smoke-testing the artifact bucket"
    MINIO_JOB_COMPLETE="$(oc get job minio-bootstrap \
        -n "${ZENML_WORKLOAD_NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
    if [[ "${MINIO_JOB_COMPLETE}" == "True" ]]; then
        success "MinIO bootstrap Job already completed."
    else
        oc delete job minio-bootstrap \
            -n "${ZENML_WORKLOAD_NAMESPACE}" \
            --ignore-not-found >/dev/null
        oc process -f "${bucket_job_template}" \
            -p "MINIO_CLIENT_IMAGE=${MINIO_CLIENT_IMAGE}" \
            -p "MINIO_SECRET_NAME=${MINIO_SECRET_NAME}" \
            -p "MINIO_BUCKET=${MINIO_BUCKET}" \
            | oc apply -n "${ZENML_WORKLOAD_NAMESPACE}" -f - >/dev/null
        oc wait --for=condition=complete job/minio-bootstrap \
            -n "${ZENML_WORKLOAD_NAMESPACE}" \
            --timeout=120s
    fi
    oc logs job/minio-bootstrap -n "${ZENML_WORKLOAD_NAMESPACE}" --tail=20
    success "Bucket ${MINIO_BUCKET} passed the MinIO write/read smoke test."
}
