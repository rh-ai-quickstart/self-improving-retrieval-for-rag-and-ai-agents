#!/usr/bin/env bash

validate_stack_load_config() {
    local config_file="$1"

    section "Loading workload-stack validation configuration"
    load_stack_config "${config_file}"
    info "Workload project: ${ZENML_WORKLOAD_NAMESPACE}"
    info "ZenML stack:      ${ZENML_STACK}"
}
