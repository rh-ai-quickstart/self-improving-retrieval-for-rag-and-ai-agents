#!/usr/bin/env bash
set -euo pipefail

# Remove ZenML workload-stack registrations, then delete the dedicated project.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/init.sh
source "${SCRIPT_DIR}/lib/init.sh"

CONFIG_FILE="${1:-${REPO_ROOT}/deployment.env}"
# shellcheck source=lib/stack_config.sh
source "${SCRIPT_DIR}/lib/stack_config.sh"
# shellcheck source=lib/zenml.sh
source "${SCRIPT_DIR}/lib/zenml.sh"
# shellcheck source=lib/delete/stack.sh
source "${SCRIPT_DIR}/lib/delete/stack.sh"

delete_stack_load_and_show "${CONFIG_FILE}"
delete_stack_confirm
delete_stack_execute
delete_stack_print_summary
