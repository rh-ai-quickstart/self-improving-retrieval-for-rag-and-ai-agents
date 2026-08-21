#!/usr/bin/env bash

component_exists() {
    local component_command="$1"
    local component_name="$2"
    zenml "${component_command}" describe "${component_name}" >/dev/null 2>&1
}

delete_component_if_present() {
    local component_command="$1"
    local component_name="$2"
    local label="$3"

    if component_exists "${component_command}" "${component_name}"; then
        zenml "${component_command}" delete "${component_name}" >/dev/null
        success "Deleted ${label}: ${component_name}"
    else
        info "${label} ${component_name} is not present; skipping."
    fi
}

component_is_registered() {
    local component_command="$1"
    local component_name="$2"
    local label="$3"

    if zenml "${component_command}" describe "${component_name}" >/dev/null 2>&1; then
        pass "${label} is registered: ${component_name}"
    else
        fail "${label} is not registered or accessible: ${component_name}"
    fi
}
