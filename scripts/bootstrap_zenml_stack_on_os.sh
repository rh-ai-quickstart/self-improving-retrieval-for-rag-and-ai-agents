#!/usr/bin/env bash
set -euo pipefail

# Provision the OpenShift resources and ZenML components for remote pipelines.
# The ZenML server must already be activated and the local CLI logged in.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/init.sh
source "${SCRIPT_DIR}/lib/init.sh"

CONFIG_FILE="${1:-${REPO_ROOT}/deployment.env}"
RESOURCE_TEMPLATE="${REPO_ROOT}/deploy/openshift/zenml-stack-resources.yaml"
BUCKET_JOB_TEMPLATE="${REPO_ROOT}/deploy/openshift/minio-bootstrap-job.yaml"
MLFLOW_TEMPLATE="${REPO_ROOT}/deploy/openshift/mlflow.yaml"
# shellcheck source=lib/stack_config.sh
source "${SCRIPT_DIR}/lib/stack_config.sh"
# shellcheck source=lib/zenml.sh
source "${SCRIPT_DIR}/lib/zenml.sh"
# shellcheck source=lib/cleanup.sh
source "${SCRIPT_DIR}/lib/cleanup.sh"
# shellcheck source=lib/bootstrap/load_config.sh
source "${SCRIPT_DIR}/lib/bootstrap/load_config.sh"
# shellcheck source=lib/bootstrap/workload_project.sh
source "${SCRIPT_DIR}/lib/bootstrap/workload_project.sh"
# shellcheck source=lib/bootstrap/mlflow.sh
source "${SCRIPT_DIR}/lib/bootstrap/mlflow.sh"
# shellcheck source=lib/bootstrap/minio.sh
source "${SCRIPT_DIR}/lib/bootstrap/minio.sh"
# shellcheck source=lib/bootstrap/registry.sh
source "${SCRIPT_DIR}/lib/bootstrap/registry.sh"
# shellcheck source=lib/bootstrap/zenml_registration.sh
source "${SCRIPT_DIR}/lib/bootstrap/zenml_registration.sh"

register_stack_cleanup

bootstrap_load_config \
    "${CONFIG_FILE}" \
    "${RESOURCE_TEMPLATE}" \
    "${BUCKET_JOB_TEMPLATE}" \
    "${MLFLOW_TEMPLATE}"
bootstrap_check_prerequisites
bootstrap_ensure_workload_project
bootstrap_setup_kserve
bootstrap_setup_mlflow "${MLFLOW_TEMPLATE}"
bootstrap_setup_minio "${RESOURCE_TEMPLATE}" "${BUCKET_JOB_TEMPLATE}"
bootstrap_setup_registry
bootstrap_register_zenml_components
bootstrap_print_summary
