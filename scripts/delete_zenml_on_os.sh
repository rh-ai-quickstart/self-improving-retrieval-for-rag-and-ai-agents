#!/usr/bin/env bash
set -euo pipefail

# Remove resources created by the ZenML OpenShift server bootstrap.
# The OpenShift project itself is deliberately retained.
#
# Usage:
#   ./scripts/delete_zenml_on_os.sh [deployment.env]
#
# Non-interactive confirmation:
#   ZENML_DELETE_CONFIRM=<project-name> \
#       ./scripts/delete_zenml_on_os.sh deployment.env

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/init.sh
source "${SCRIPT_DIR}/lib/init.sh"

CONFIG_FILE="${1:-${REPO_ROOT}/deployment.env}"
# shellcheck source=lib/delete/server.sh
source "${SCRIPT_DIR}/lib/delete/server.sh"

delete_server_load_config "${CONFIG_FILE}"
delete_server_show_resources
delete_server_confirm
delete_server_execute
delete_server_verify
