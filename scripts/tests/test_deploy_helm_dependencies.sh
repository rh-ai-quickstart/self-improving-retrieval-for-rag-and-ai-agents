#!/usr/bin/env bash
set -euo pipefail

# Regression test: the default uses the bundled chart, while an explicit
# ZENML_VERSION prepares an isolated chart that pulls anonymously from ECR.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_UNDER_TEST="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zenml-helm-dependencies.XXXXXX")"
trap 'rm -rf "${TEST_ROOT}"' EXIT

mkdir -p \
    "${TEST_ROOT}/deploy/helm/zenml-server" \
    "${TEST_ROOT}/deploy/helm/vendor/zenml"

printf '%s\n' \
    'apiVersion: v2' \
    'name: zenml' \
    'type: application' \
    'version: 0.96.2' \
    > "${TEST_ROOT}/deploy/helm/vendor/zenml/Chart.yaml"

printf '%s\n' \
    'apiVersion: v2' \
    'name: zenml-server' \
    'type: application' \
    'version: 0.1.0' \
    'dependencies:' \
    '  - name: zenml' \
    '    version: "0.96.2"' \
    '    repository: file://../vendor/zenml' \
    '    condition: zenml.enabled' \
    > "${TEST_ROOT}/deploy/helm/zenml-server/Chart.yaml"

helm dependency update "${TEST_ROOT}/deploy/helm/zenml-server" >/dev/null

REPO_ROOT="${TEST_ROOT}"

info() { :; }
success() { :; }
die() { echo "ERROR: $*" >&2; return 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

# shellcheck source=../lib/zenml_version.sh
source "${REPO_ROOT_UNDER_TEST}/scripts/lib/zenml_version.sh"
unset ZENML_VERSION
zenml_resolve_version
[[ "${ZENML_VERSION}" == 0.96.2 ]]
[[ "${ZENML_VERSION_SOURCE}" == bundled ]]

HELM_DEPENDENCY_ACTION=""
HELM_DEPENDENCY_ARGUMENTS=""
run_logged() {
    if [[ "$1" == helm && "$2" == dependency ]]; then
        HELM_DEPENDENCY_ACTION="$3"
        HELM_DEPENDENCY_ARGUMENTS="$*"
        if [[ "${ZENML_VERSION_SOURCE}" == ecr ]]; then
            return 0
        fi
    fi
    "$@"
}

# shellcheck source=../lib/cleanup.sh
source "${REPO_ROOT_UNDER_TEST}/scripts/lib/cleanup.sh"
# shellcheck source=../lib/deploy/helm.sh
source "${REPO_ROOT_UNDER_TEST}/scripts/lib/deploy/helm.sh"

deploy_update_chart_dependencies

[[ "${HELM_DEPENDENCY_ACTION}" == update ]]
[[ "${SERVER_CHART_PATH}" != "${TEST_ROOT}/deploy/helm/zenml-server" ]]
[[ -f "${SERVER_CHART_PATH}/charts/zenml-0.96.2.tgz" ]]

ZENML_VERSION="0.96.1"
zenml_resolve_version
[[ "${ZENML_VERSION_SOURCE}" == ecr ]]
deploy_update_chart_dependencies

[[ "${HELM_DEPENDENCY_ACTION}" == update ]]
[[ "${SERVER_CHART_PATH}" != "${TEST_ROOT}/deploy/helm/zenml-server" ]]
grep -Fq 'version: "0.96.1"' "${SERVER_CHART_PATH}/Chart.yaml"
grep -Fq 'repository: oci://public.ecr.aws/zenml' "${SERVER_CHART_PATH}/Chart.yaml"
grep -Fq 'version: "0.96.2"' \
    "${TEST_ROOT}/deploy/helm/zenml-server/Chart.yaml"
grep -Fq 'repository: file://../vendor/zenml' \
    "${TEST_ROOT}/deploy/helm/zenml-server/Chart.yaml"
[[ "${HELM_DEPENDENCY_ARGUMENTS}" == *"--registry-config"* ]]
grep -Fq '{"auths":{}}' \
    "${SERVER_CHART_PATH%/zenml-server}/anonymous-registry-config.json"

runtime_chart_root="${SERVER_CHART_PATH%/zenml-server}"
cleanup
[[ ! -d "${runtime_chart_root}" ]]

echo "PASS: bundled default and anonymous ECR override are selected correctly"
