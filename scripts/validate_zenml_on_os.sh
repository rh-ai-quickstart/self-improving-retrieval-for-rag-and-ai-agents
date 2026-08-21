#!/usr/bin/env bash
set -uo pipefail

# Validate an existing ZenML OSS deployment on OpenShift without changing it.
#
# Usage:
#   ./scripts/validate_zenml_on_os.sh [deployment.env]

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

# shellcheck source=lib/init.sh
source "${SCRIPT_DIR}/lib/init.sh"

CONFIG_FILE="${1:-${REPO_ROOT}/deployment.env}"
# shellcheck source=lib/validation_output.sh
source "${SCRIPT_DIR}/lib/validation_output.sh"
# shellcheck source=lib/validate/server/load_config.sh
source "${SCRIPT_DIR}/lib/validate/server/load_config.sh"
# shellcheck source=lib/validate/server/clients.sh
source "${SCRIPT_DIR}/lib/validate/server/clients.sh"
# shellcheck source=lib/validate/server/project_and_helm.sh
source "${SCRIPT_DIR}/lib/validate/server/project_and_helm.sh"
# shellcheck source=lib/validate/server/zenml_workload.sh
source "${SCRIPT_DIR}/lib/validate/server/zenml_workload.sh"
# shellcheck source=lib/validate/server/database.sh
source "${SCRIPT_DIR}/lib/validate/server/database.sh"
# shellcheck source=lib/validate/server/route_and_health.sh
source "${SCRIPT_DIR}/lib/validate/server/route_and_health.sh"
# shellcheck source=lib/validate/server/summary.sh
source "${SCRIPT_DIR}/lib/validate/server/summary.sh"

validate_server_load_config "${CONFIG_FILE}"
validate_server_check_clients
validate_server_check_project
validate_server_check_helm
validate_server_check_zenml_workload
validate_server_check_database
validate_server_check_route
validate_server_check_health
validate_server_print_summary
