#!/usr/bin/env bash

validate_stack_check_clients() {
    section "Checking local clients and authenticated services"
    OC_AVAILABLE=false
    CURL_AVAILABLE=false
    DOCKER_AVAILABLE=false
    ZENML_AVAILABLE=false
    PYTHON_AVAILABLE=false

    command_available oc && OC_AVAILABLE=true
    command_available curl && CURL_AVAILABLE=true
    command_available docker && DOCKER_AVAILABLE=true
    command_available zenml && ZENML_AVAILABLE=true
    command_available "${ZENML_PYTHON}" && PYTHON_AVAILABLE=true

    if [[ "${OC_AVAILABLE}" == true ]] && OPENSHIFT_USER="$(oc whoami 2>/dev/null)"; then
        pass "Authenticated to OpenShift as ${OPENSHIFT_USER}"
    else
        fail "The oc CLI is not authenticated to OpenShift."
        OC_AVAILABLE=false
    fi

    if [[ "${ZENML_AVAILABLE}" == true ]] && zenml status >/dev/null 2>&1; then
        pass "The ZenML CLI is authenticated."
    else
        fail "The ZenML CLI is not authenticated to the deployed server."
        ZENML_AVAILABLE=false
    fi

    if [[ "${DOCKER_AVAILABLE}" == true ]] && docker info >/dev/null 2>&1; then
        pass "The local Docker daemon is reachable."
    else
        fail "The local Docker daemon is not reachable."
        DOCKER_AVAILABLE=false
    fi

    if [[ "${PYTHON_AVAILABLE}" == true ]]; then
        CLIENT_VERSION="$("${ZENML_PYTHON}" -c 'import zenml; print(zenml.__version__)' 2>/dev/null || true)"
        if [[ "${CLIENT_VERSION}" == "${ZENML_VERSION}" ]]; then
            pass "ZenML Python client matches the configured server version: ${ZENML_VERSION}"
        else
            fail "ZenML Python client version is ${CLIENT_VERSION:-unavailable}; expected ${ZENML_VERSION}."
        fi

        if "${ZENML_PYTHON}" -c 'import docker; assert docker.from_env().ping()' >/dev/null 2>&1; then
            pass "The ZenML Python environment can reach Docker through the Docker SDK."
        else
            fail "The ZenML Python environment cannot reach Docker through the Docker SDK."
        fi

        MLFLOW_VERSION="$("${ZENML_PYTHON}" -c 'import mlflow; print(mlflow.__version__)' 2>/dev/null || true)"
        if [[ -n "${MLFLOW_VERSION}" ]]; then
            pass "ZenML-managed MLflow SDK is installed: ${MLFLOW_VERSION}"
        else
            fail "MLflow SDK is unavailable. Run 'just bootstrap-stack' to install the ZenML MLflow integration."
        fi
    fi
}
