#!/usr/bin/env bash
set -euo pipefail

# Read-only validation for the KServe model created by the ZenML pipeline.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/init.sh
source "${SCRIPT_DIR}/lib/init.sh"

CONFIG_FILE="${1:-${REPO_ROOT}/deployment.env}"
# shellcheck source=lib/stack_config.sh
source "${SCRIPT_DIR}/lib/stack_config.sh"
# shellcheck source=lib/cleanup.sh
source "${SCRIPT_DIR}/lib/cleanup.sh"
# shellcheck source=lib/validate/model/inference.sh
source "${SCRIPT_DIR}/lib/validate/model/inference.sh"
# shellcheck source=lib/validate/model/api.sh
source "${SCRIPT_DIR}/lib/validate/model/api.sh"

register_model_validation_cleanup

section "Loading model-serving validation configuration"
load_stack_config "${CONFIG_FILE}"
require_command oc
require_command curl
require_command "${ZENML_PYTHON}"

oc whoami >/dev/null 2>&1 \
    || die "The oc CLI is not authenticated to OpenShift."

validate_model_check_inference
validate_model_call_api

section "Model-serving validation completed"
success "The ZenML-selected model is deployed by OpenShift AI KServe and responding."
