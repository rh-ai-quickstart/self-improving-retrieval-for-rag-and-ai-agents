#!/usr/bin/env bash
set -euo pipefail

# Refresh only the short-lived credentials used by an existing remote stack.
# This script intentionally does not provision infrastructure or registrations.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/init.sh
source "${SCRIPT_DIR}/lib/init.sh"

CONFIG_FILE="${1:-${REPO_ROOT}/deployment.env}"
# shellcheck source=lib/stack_config.sh
source "${SCRIPT_DIR}/lib/stack_config.sh"
# shellcheck source=lib/jwt.sh
source "${SCRIPT_DIR}/lib/jwt.sh"
# shellcheck source=lib/refresh/credentials.sh
source "${SCRIPT_DIR}/lib/refresh/credentials.sh"

refresh_stack_credentials "${CONFIG_FILE}"
