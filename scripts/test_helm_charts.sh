#!/usr/bin/env bash
set -euo pipefail

# Lint, render, and unit-test the OpenShift Helm charts without a cluster.
#
# Usage:
#   ./scripts/test_helm_charts.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

STACK_CHART="${REPO_ROOT}/deploy/helm/zenml-stack"
SERVER_CHART="${REPO_ROOT}/deploy/helm/zenml-server"
STACK_VALUES="${STACK_CHART}/secrets.yaml.example"
SERVER_VALUES_FILE="${SERVER_CHART}/values-openshift.yaml"
SERVER_SECRETS_FILE="${SERVER_CHART}/secrets.yaml.example"
HELM_UNITTEST_VERSION="${HELM_UNITTEST_VERSION:-0.7.2}"

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: Required command not found: $1" >&2
        exit 1
    }
}

ensure_helm_unittest() {
    if helm unittest --help >/dev/null 2>&1; then
        return 0
    fi

    echo "==> Installing helm-unittest plugin v${HELM_UNITTEST_VERSION}"
    helm plugin install "https://github.com/helm-unittest/helm-unittest" \
        --version "v${HELM_UNITTEST_VERSION}"
}

ensure_helm_repositories() {
    echo "==> Ensuring Helm chart repositories"
    if ! helm repo list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx bitnami; then
        helm repo add bitnami https://charts.bitnami.com/bitnami
    fi
    helm repo update bitnami
}

run_stack_chart_tests() {
    echo "==> Linting zenml-stack"
    helm lint "${STACK_CHART}" -f "${STACK_VALUES}"

    echo "==> Rendering zenml-stack"
    helm template zenml-stack "${STACK_CHART}" \
        --namespace zenml-workloads \
        -f "${STACK_VALUES}" >/dev/null

    echo "==> Running zenml-stack unit tests"
    helm unittest "${STACK_CHART}"
}

run_server_chart_tests() {
    ensure_helm_repositories

    echo "==> Building zenml-server chart dependencies"
    helm dependency build "${SERVER_CHART}"

    echo "==> Linting zenml-server"
    helm lint "${SERVER_CHART}" \
        -f "${SERVER_VALUES_FILE}" \
        -f "${SERVER_SECRETS_FILE}"

    echo "==> Rendering zenml-server"
    helm template zenml-server "${SERVER_CHART}" \
        --namespace zenml \
        -f "${SERVER_VALUES_FILE}" \
        -f "${SERVER_SECRETS_FILE}" >/dev/null

    echo "==> Running zenml-server unit tests"
    helm unittest "${SERVER_CHART}"
}

main() {
    require_command helm
    ensure_helm_unittest

    run_stack_chart_tests
    run_server_chart_tests

    echo "==> Helm chart tests completed successfully"
}

main "$@"
