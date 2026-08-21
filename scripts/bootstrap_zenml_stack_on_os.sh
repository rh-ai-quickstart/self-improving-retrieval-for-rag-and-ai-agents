#!/usr/bin/env bash
set -euo pipefail

# Provision the OpenShift resources and ZenML components for remote pipelines.
# The ZenML server must already be activated and the local CLI logged in.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/init.sh
source "${SCRIPT_DIR}/lib/init.sh"

CONFIG_FILE="${1:-${REPO_ROOT}/deployment.env}"

# shellcheck source=lib/stack_config.sh
source "${SCRIPT_DIR}/lib/stack_config.sh"
# shellcheck source=lib/zenml.sh
source "${SCRIPT_DIR}/lib/zenml.sh"
# shellcheck source=lib/cleanup.sh
source "${SCRIPT_DIR}/lib/cleanup.sh"
# shellcheck source=lib/bootstrap/load_config.sh
source "${SCRIPT_DIR}/lib/bootstrap/load_config.sh"
# shellcheck source=lib/bootstrap/helm.sh
source "${SCRIPT_DIR}/lib/bootstrap/helm.sh"
# shellcheck source=lib/bootstrap/registry.sh
source "${SCRIPT_DIR}/lib/bootstrap/registry.sh"
# shellcheck source=lib/bootstrap/zenml_registration.sh
source "${SCRIPT_DIR}/lib/bootstrap/zenml_registration.sh"

register_stack_cleanup

bootstrap_load_config "${CONFIG_FILE}"
bootstrap_check_prerequisites
bootstrap_verify_openshift_ai
bootstrap_install_stack_chart
bootstrap_wait_for_stack
bootstrap_setup_registry
bootstrap_register_zenml_components
bootstrap_print_summary
