#!/usr/bin/env bash
set -euo pipefail

# Deploy ZenML OSS and a persistent MySQL database on OpenShift.
#
# Usage:
#   ./scripts/deploy_zenml_on_os.sh [deployment.env]
#
# If no path is supplied, deployment.env in the repository root is used.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/init.sh
source "${SCRIPT_DIR}/lib/init.sh"

CONFIG_FILE="${1:-${REPO_ROOT}/deployment.env}"
VALUES_FILE="${REPO_ROOT}/deploy/helm/zenml-server/values-openshift.yaml"

# shellcheck source=lib/cleanup.sh
source "${SCRIPT_DIR}/lib/cleanup.sh"
# shellcheck source=lib/deploy/load_config.sh
source "${SCRIPT_DIR}/lib/deploy/load_config.sh"
# shellcheck source=lib/deploy/prerequisites.sh
source "${SCRIPT_DIR}/lib/deploy/prerequisites.sh"
# shellcheck source=lib/deploy/helm.sh
source "${SCRIPT_DIR}/lib/deploy/helm.sh"
# shellcheck source=lib/deploy/route_and_health.sh
source "${SCRIPT_DIR}/lib/deploy/route_and_health.sh"

setup_cleanup_trap

deploy_load_config "${CONFIG_FILE}" "${VALUES_FILE}"
deploy_check_prerequisites
deploy_ensure_project
deploy_check_storage
deploy_prepare_database_credentials
# Two-step Helm: MySQL-only, wait until zenml-mysql is Ready, then enable ZenML
# so the pre-install db-migration Job can resolve the database Service.
deploy_install_helm "${VALUES_FILE}"
deploy_wait_for_mysql
deploy_wait_for_zenml
deploy_verify_route
deploy_check_health
deploy_print_summary
