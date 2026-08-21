#!/usr/bin/env bash

# Shared initialization for ZenML OpenShift scripts.
# Entry scripts must set SCRIPT_DIR before sourcing this file.

REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"
init_script_logging

# shellcheck source=output.sh
source "${SCRIPT_DIR}/lib/output.sh"
# shellcheck source=commands.sh
source "${SCRIPT_DIR}/lib/commands.sh"
# shellcheck source=dns.sh
source "${SCRIPT_DIR}/lib/dns.sh"
