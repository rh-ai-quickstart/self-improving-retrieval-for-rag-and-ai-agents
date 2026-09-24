#!/usr/bin/env bash

zenml_resolve_version() {
    ZENML_VERSION="${ZENML_VERSION:-}"
    if [[ -n "${ZENML_VERSION}" ]]; then
        ZENML_VERSION_SOURCE="ecr"
        return 0
    fi

    local bundled_chart="${REPO_ROOT}/deploy/helm/vendor/zenml/Chart.yaml"
    [[ -f "${bundled_chart}" ]] \
        || die "Bundled ZenML chart metadata not found: ${bundled_chart}"

    ZENML_VERSION="$(awk '$1 == "version:" {print $2; exit}' "${bundled_chart}")"
    [[ -n "${ZENML_VERSION}" ]] \
        || die "Could not read the bundled ZenML version from ${bundled_chart}."
    ZENML_VERSION_SOURCE="bundled"
}
