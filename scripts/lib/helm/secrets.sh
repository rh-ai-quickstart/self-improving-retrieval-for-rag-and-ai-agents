#!/usr/bin/env bash

helm_secrets_file() {
    local chart_path="$1"
    echo "${chart_path}/secrets.yaml"
}

helm_ensure_secrets_file() {
    local chart_path="$1"
    local secrets_file example_file

    secrets_file="$(helm_secrets_file "${chart_path}")"
    example_file="${chart_path}/secrets.yaml.example"

    [[ -f "${example_file}" ]] || die "Helm secrets example not found: ${example_file}"

    if [[ ! -f "${secrets_file}" ]]; then
        cp "${example_file}" "${secrets_file}"
        chmod 600 "${secrets_file}"
        info "Created ${secrets_file} from secrets.yaml.example."
    fi
}
