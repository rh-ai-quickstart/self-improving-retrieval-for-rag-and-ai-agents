set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

# Override with: DEPLOYMENT_ENV=deployment.lab.env just bootstrap-server
deployment_env := env_var_or_default("DEPLOYMENT_ENV", "deployment.env")

# List the available project commands.
default:
    @just --list

# Start phase 1. Activate the server and authenticate the CLI before phase 2.
bootstrap: bootstrap-server

# Phase 1: provision persistent MySQL, ZenML OSS, and the OpenShift Route.
bootstrap-server:
    @echo "==> Bootstrapping the ZenML server infrastructure"
    @echo "    Configuration: {{deployment_env}}"
    @if [[ ! -f "{{deployment_env}}" ]]; then \
        echo "ERROR: Configuration file not found: {{deployment_env}}" >&2; \
        echo "Create it with: cp deployment.env.example deployment.env" >&2; \
        exit 1; \
    fi
    ./scripts/deploy_zenml_on_os.sh "{{deployment_env}}"
    @echo
    @echo "==> Server bootstrap complete"
    @echo "    Complete browser activation and run 'zenml login <route-url>'."
    @echo "    Then run 'just bootstrap-stack'."

# Phase 2: provision and register the remote workload stack.
bootstrap-stack:
    @echo "==> Bootstrapping the ZenML remote workload stack"
    @echo "    Configuration: {{deployment_env}}"
    @if [[ ! -f "{{deployment_env}}" ]]; then \
        echo "ERROR: Configuration file not found: {{deployment_env}}" >&2; \
        echo "Create it with: cp deployment.env.example deployment.env" >&2; \
        exit 1; \
    fi
    ./scripts/bootstrap_zenml_stack_on_os.sh "{{deployment_env}}"

# Validate both phases without modifying OpenShift or ZenML resources.
validate:
    @just validate-server
    @just validate-stack

# Check Helm, workloads, storage, Services, Route, and HTTP health.
validate-server:
    @echo "==> Validating the ZenML server infrastructure"
    @echo "    Configuration: {{deployment_env}}"
    @if [[ ! -f "{{deployment_env}}" ]]; then \
        echo "ERROR: Configuration file not found: {{deployment_env}}" >&2; \
        echo "Create it with: cp deployment.env.example deployment.env" >&2; \
        exit 1; \
    fi
    ./scripts/validate_zenml_on_os.sh "{{deployment_env}}"

# Check workload resources, registry access, Docker, and ZenML registrations.
validate-stack:
    @echo "==> Validating the ZenML remote workload stack"
    @echo "    Configuration: {{deployment_env}}"
    @if [[ ! -f "{{deployment_env}}" ]]; then \
        echo "ERROR: Configuration file not found: {{deployment_env}}" >&2; \
        echo "Create it with: cp deployment.env.example deployment.env" >&2; \
        exit 1; \
    fi
    ./scripts/validate_zenml_stack_on_os.sh "{{deployment_env}}"

# Remove phase 2 before phase 1 so its ZenML registrations remain reachable.
delete:
    @just delete-stack
    @just delete-server

# Remove ZenML stack registrations and the dedicated workload project.
delete-stack:
    @echo "==> Tearing down the ZenML remote workload stack"
    @echo "    Configuration: {{deployment_env}}"
    @if [[ ! -f "{{deployment_env}}" ]]; then \
        echo "ERROR: Configuration file not found: {{deployment_env}}" >&2; \
        exit 1; \
    fi
    ./scripts/delete_zenml_stack_on_os.sh "{{deployment_env}}"

# Remove the ZenML server, Route, persistent MySQL database, and PVCs.
delete-server:
    @echo "==> Tearing down the ZenML server infrastructure"
    @echo "    Configuration: {{deployment_env}}"
    @if [[ ! -f "{{deployment_env}}" ]]; then \
        echo "ERROR: Configuration file not found: {{deployment_env}}" >&2; \
        exit 1; \
    fi
    ./scripts/delete_zenml_on_os.sh "{{deployment_env}}"
