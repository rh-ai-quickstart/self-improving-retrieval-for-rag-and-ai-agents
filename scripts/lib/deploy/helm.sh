#!/usr/bin/env bash

deploy_install_helm() {
    local values_file="$1"

    section "Checking the current Helm release state"

    if helm status "${ZENML_RELEASE}" -n "${ZENML_NAMESPACE}" >/dev/null 2>&1; then
        HELM_STATUS="$(helm status "${ZENML_RELEASE}" -n "${ZENML_NAMESPACE}" | awk '/^STATUS:/ {print $2}')"
        info "Existing release status: ${HELM_STATUS:-unknown}"
        if [[ "${HELM_STATUS}" == pending-* ]]; then
            helm history "${ZENML_RELEASE}" -n "${ZENML_NAMESPACE}" || true
            die "Helm release ${ZENML_RELEASE} is ${HELM_STATUS}. Resolve the pending operation or roll back to the latest deployed revision before retrying."
        fi
    else
        info "No existing Helm release was found; this will be a new installation."
    fi

    section "Installing or upgrading ZenML with Helm"

    info "Chart:     oci://public.ecr.aws/zenml/zenml"
    info "Version:   ${ZENML_VERSION}"
    info "Release:   ${ZENML_RELEASE}"
    info "Namespace: ${ZENML_NAMESPACE}"
    info "Values:    ${values_file}"
    info "Database settings are supplied as non-secret Helm overrides."

    run_logged helm upgrade --install "${ZENML_RELEASE}" \
        oci://public.ecr.aws/zenml/zenml \
        --version "${ZENML_VERSION}" \
        --namespace "${ZENML_NAMESPACE}" \
        --values "${values_file}" \
        --set-string "server.database.url=${ZENML_DATABASE_URL}" \
        --set-string "server.database.passwordSecretRef.name=${ZENML_DB_PASSWORD_SECRET}" \
        --set-string "server.database.passwordSecretRef.key=password" \
        --wait \
        --timeout 5m

    success "Helm installation/upgrade completed."

    info "Waiting for the ZenML server Deployment rollout."
    run_logged oc rollout status "deployment/${ZENML_RELEASE}" \
        -n "${ZENML_NAMESPACE}" \
        --timeout=180s
    success "ZenML server rollout completed."
}
