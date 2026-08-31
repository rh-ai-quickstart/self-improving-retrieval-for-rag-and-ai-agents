#!/usr/bin/env bash

bootstrap_load_config() {
    local config_file="$1"

    section "Loading workload-stack configuration"
    load_stack_config "${config_file}"

    info "Workload project:    ${ZENML_WORKLOAD_NAMESPACE}"
    info "Orchestrator SA:     ${ZENML_ORCHESTRATOR_SA}"
    info "ZenML stack:         ${ZENML_STACK}"
    info "Helm release:        ${ZENML_STACK_RELEASE:-zenml-stack}"
    info "MinIO image:         ${MINIO_IMAGE}"
    info "MinIO client image:  ${MINIO_CLIENT_IMAGE}"
    info "MinIO storage:       ${MINIO_STORAGE_CLASS}/${MINIO_STORAGE_SIZE}"
    info "MinIO bucket:        ${MINIO_BUCKET}"
    info "MLflow instance:     ${MLFLOW_INSTANCE}"
    info "Experiment tracker:  ${ZENML_EXPERIMENT_TRACKER}"
    info "KServe model:        ${MODEL_SERVING_NAME}"
}

bootstrap_check_prerequisites() {
    section "Checking local clients and authenticated services"
    require_command oc
    require_command curl
    require_command docker
    require_command zenml
    require_command openssl
    require_command python3
    require_command helm
    require_command "${ZENML_PYTHON}"

    oc whoami >/dev/null 2>&1 || die "The oc CLI is not authenticated to OpenShift."
    zenml status >/dev/null 2>&1 || die "The ZenML CLI is not authenticated to the deployed server."
    docker info >/dev/null 2>&1 || die "The local Docker daemon is not reachable."

    CLIENT_VERSION="$("${ZENML_PYTHON}" -c 'import zenml; print(zenml.__version__)')"
    [[ "${CLIENT_VERSION}" == "${ZENML_VERSION}" ]] || die "ZenML Python client ${CLIENT_VERSION} does not match configured server version ${ZENML_VERSION}."

    info "Installing the required ZenML integration dependencies."
    zenml integration install s3 mlflow -y
    success "ZenML S3 and MLflow integration dependencies are installed."

    "${ZENML_PYTHON}" -c 'import docker; assert docker.from_env().ping()' >/dev/null \
        || die "The ZenML Python environment cannot reach Docker through the Docker SDK."
    OPENSHIFT_USER="$(oc whoami)"
    OPENSHIFT_SERVER="$(oc whoami --show-server)"
    success "Authenticated to OpenShift as ${OPENSHIFT_USER}"
    success "ZenML client/server version is ${ZENML_VERSION}"
    success "Docker CLI and Python SDK can reach the daemon"
}
