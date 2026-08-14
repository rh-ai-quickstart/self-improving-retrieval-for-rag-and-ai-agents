set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

# Override with: DEPLOYMENT_ENV=deployment.lab.env just bootstrap-server
deployment_env := env_var_or_default("DEPLOYMENT_ENV", "deployment.env")

# List the available project commands.
default:
    @just --list

# Start the bootstrap workflow. Phase 2 remains separate because ZenML must be
# activated and the local CLI must be authenticated before stack registration.
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
    @echo "    Then run 'just bootstrap-stack' once the stack bootstrap is added."

# Validate phase 1 without modifying any OpenShift resources.
validate: validate-server

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

# Tear down the complete quickstart. This currently aliases phase 1; when the
# stack bootstrap lands, delete-stack can run before delete-server.
delete: delete-server

# Remove the ZenML server, Route, persistent MySQL database, and PVCs.
delete-server:
    @echo "==> Tearing down the ZenML server infrastructure"
    @echo "    Configuration: {{deployment_env}}"
    @if [[ ! -f "{{deployment_env}}" ]]; then \
        echo "ERROR: Configuration file not found: {{deployment_env}}" >&2; \
        exit 1; \
    fi
    ./scripts/delete_zenml_on_os.sh "{{deployment_env}}"
