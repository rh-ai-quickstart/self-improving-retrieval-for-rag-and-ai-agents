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
VALUES_FILE="${REPO_ROOT}/deploy/helm/openshift-values.yaml"
# shellcheck source=lib/cleanup.sh
source "${SCRIPT_DIR}/lib/cleanup.sh"
# shellcheck source=lib/deploy/load_config.sh
source "${SCRIPT_DIR}/lib/deploy/load_config.sh"
# shellcheck source=lib/deploy/prerequisites.sh
source "${SCRIPT_DIR}/lib/deploy/prerequisites.sh"
# shellcheck source=lib/deploy/database.sh
source "${SCRIPT_DIR}/lib/deploy/database.sh"
# shellcheck source=lib/deploy/helm.sh
source "${SCRIPT_DIR}/lib/deploy/helm.sh"
# shellcheck source=lib/deploy/route_and_health.sh
source "${SCRIPT_DIR}/lib/deploy/route_and_health.sh"

setup_cleanup_trap

deploy_load_config "${CONFIG_FILE}" "${VALUES_FILE}"
deploy_check_prerequisites
deploy_ensure_project
deploy_check_storage_and_template
deploy_provision_database
deploy_install_helm "${VALUES_FILE}"
deploy_ensure_route
deploy_check_health
deploy_print_summary
