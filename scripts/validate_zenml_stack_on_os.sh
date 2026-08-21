#!/usr/bin/env bash
set -uo pipefail

# Validate the remote ZenML workload stack without changing OpenShift or ZenML.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

# shellcheck source=lib/init.sh
source "${SCRIPT_DIR}/lib/init.sh"

CONFIG_FILE="${1:-${REPO_ROOT}/deployment.env}"
# shellcheck source=lib/stack_config.sh
source "${SCRIPT_DIR}/lib/stack_config.sh"
# shellcheck source=lib/zenml.sh
source "${SCRIPT_DIR}/lib/zenml.sh"
# shellcheck source=lib/validation_output.sh
source "${SCRIPT_DIR}/lib/validation_output.sh"
# shellcheck source=lib/validate/stack/load_config.sh
source "${SCRIPT_DIR}/lib/validate/stack/load_config.sh"
# shellcheck source=lib/validate/stack/clients.sh
source "${SCRIPT_DIR}/lib/validate/stack/clients.sh"
# shellcheck source=lib/validate/stack/project.sh
source "${SCRIPT_DIR}/lib/validate/stack/project.sh"
# shellcheck source=lib/validate/stack/kserve.sh
source "${SCRIPT_DIR}/lib/validate/stack/kserve.sh"
# shellcheck source=lib/validate/stack/mlflow.sh
source "${SCRIPT_DIR}/lib/validate/stack/mlflow.sh"
# shellcheck source=lib/validate/stack/minio.sh
source "${SCRIPT_DIR}/lib/validate/stack/minio.sh"
# shellcheck source=lib/validate/stack/registry.sh
source "${SCRIPT_DIR}/lib/validate/stack/registry.sh"
# shellcheck source=lib/validate/stack/registrations.sh
source "${SCRIPT_DIR}/lib/validate/stack/registrations.sh"
# shellcheck source=lib/validate/stack/summary.sh
source "${SCRIPT_DIR}/lib/validate/stack/summary.sh"

validate_stack_load_config "${CONFIG_FILE}"
validate_stack_check_clients
validate_stack_check_project
validate_stack_check_kserve
validate_stack_check_mlflow
validate_stack_check_minio
validate_stack_check_registry
validate_stack_check_registrations
validate_stack_print_summary
