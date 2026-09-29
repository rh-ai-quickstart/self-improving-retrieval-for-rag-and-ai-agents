#!/usr/bin/env bash

bootstrap_load_config() {
    local config_file="$1"

    section "Loading workload-stack configuration"
    load_stack_config "${config_file}"

    info "Workload project:    ${ZENML_WORKLOAD_NAMESPACE}"
    info "Orchestrator SA:     ${ZENML_ORCHESTRATOR_SA}"
    info "ZenML stack:         ${ZENML_STACK}"
    info "Helm release:        ${ZENML_STACK_RELEASE:-zenml-stack}"
    info "S4 image:            ${S4_IMAGE_REPOSITORY}:${S4_IMAGE_TAG}"
    info "S4 client image:     ${S4_CLIENT_IMAGE}"
    info "S4 storage:          ${S4_STORAGE_CLASS}/${S4_STORAGE_SIZE}"
    info "S4 bucket:           ${S4_BUCKET}"
    info "S4 in-cluster S3:    ${S4_INCLUSTER_ENDPOINT}"
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
    # zenml may pull a newer s3fs that conflicts with datasets' fsspec cap;
    # re-apply the pins from apps/pyproject.toml.
    "${ZENML_PYTHON}" -m pip install -q \
        'fsspec[http]==2026.2.0' \
        's3fs==2026.2.0'
    success "ZenML S3 and MLflow integration dependencies are installed."

    "${ZENML_PYTHON}" -c 'import docker; assert docker.from_env().ping()' >/dev/null \
        || die "The ZenML Python environment cannot reach Docker through the Docker SDK."
    OPENSHIFT_USER="$(oc whoami)"
    OPENSHIFT_SERVER="$(oc whoami --show-server)"
    success "Authenticated to OpenShift as ${OPENSHIFT_USER}"
    success "ZenML client/server version is ${ZENML_VERSION}"
    success "Docker CLI and Python SDK can reach the daemon"
}
