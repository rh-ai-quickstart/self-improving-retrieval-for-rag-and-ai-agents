#!/usr/bin/env bash

validate_dns_name() {
    local label="$1"
    local value="$2"

    if [[ ! "${value}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
        die "${label} must be a lowercase DNS label: ${value}"
    fi
}
