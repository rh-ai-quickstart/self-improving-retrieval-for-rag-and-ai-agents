# Override with: DEPLOYMENT_ENV=deployment.lab.env make bootstrap-server
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

DEPLOYMENT_ENV ?= deployment.env
PIPELINE_ARGS ?=

.PHONY: default help bootstrap bootstrap-server bootstrap-stack validate validate-server validate-stack refresh-stack-credentials run-pipeline validate-model delete delete-stack delete-server helm-lint helm-template test

default: help

help:
	@echo "Available targets:"
	@echo "  bootstrap                 Start phase 1 (alias for bootstrap-server)"
	@echo "  bootstrap-server          Provision persistent MySQL, ZenML OSS, and the OpenShift Route"
	@echo "  bootstrap-stack           Provision and register the remote workload stack"
	@echo "  validate                  Validate both server and stack without modifying resources"
	@echo "  validate-server           Check Helm, workloads, storage, Services, Route, and HTTP health"
	@echo "  validate-stack            Check workload resources, registry access, Docker, and ZenML registrations"
	@echo "  refresh-stack-credentials Refresh Kubernetes, registry, and MLflow credentials"
	@echo "  run-pipeline              Evaluate models, index the winner, and deploy search (PIPELINE_ARGS=--smoke for a fast run)"
	@echo "  validate-model            Check the KServe search UI and APIs"
	@echo "  delete                    Remove stack first, then server"
	@echo "  delete-stack              Remove ZenML stack registrations and the dedicated workload project"
	@echo "  delete-server             Remove the ZenML server, Route, persistent MySQL database, and PVCs"
	@echo "  helm-lint                 Lint the OpenShift Helm charts"
	@echo "  helm-template             Render the OpenShift Helm charts locally"
	@echo "  test                      Run the offline apps unit test suite"

# Start phase 1. Activate the server and authenticate the CLI before phase 2.
bootstrap: bootstrap-server

# Phase 1: provision persistent MySQL, ZenML OSS, and the OpenShift Route.
bootstrap-server:
	@echo "==> Bootstrapping the ZenML server infrastructure"
	@echo "    Configuration: $(DEPLOYMENT_ENV)"
	@if [[ ! -f "$(DEPLOYMENT_ENV)" ]]; then \
		echo "ERROR: Configuration file not found: $(DEPLOYMENT_ENV)" >&2; \
		echo "Create it with: cp deployment.env.example deployment.env" >&2; \
		exit 1; \
	fi
	./scripts/deploy_zenml_on_os.sh "$(DEPLOYMENT_ENV)"
	@echo
	@echo "==> Server bootstrap complete"
	@echo "    Complete browser activation and run 'zenml login <route-url>'."
	@echo "    Then run 'make bootstrap-stack'."

# Phase 2: provision and register the remote workload stack.
bootstrap-stack:
	@echo "==> Bootstrapping the ZenML remote workload stack"
	@echo "    Configuration: $(DEPLOYMENT_ENV)"
	@if [[ ! -f "$(DEPLOYMENT_ENV)" ]]; then \
		echo "ERROR: Configuration file not found: $(DEPLOYMENT_ENV)" >&2; \
		echo "Create it with: cp deployment.env.example deployment.env" >&2; \
		exit 1; \
	fi
	./scripts/bootstrap_zenml_stack_on_os.sh "$(DEPLOYMENT_ENV)"

# Validate both phases without modifying OpenShift or ZenML resources.
validate: validate-server validate-stack

# Check Helm, workloads, storage, Services, Route, and HTTP health.
validate-server:
	@echo "==> Validating the ZenML server infrastructure"
	@echo "    Configuration: $(DEPLOYMENT_ENV)"
	@if [[ ! -f "$(DEPLOYMENT_ENV)" ]]; then \
		echo "ERROR: Configuration file not found: $(DEPLOYMENT_ENV)" >&2; \
		echo "Create it with: cp deployment.env.example deployment.env" >&2; \
		exit 1; \
	fi
	./scripts/validate_zenml_on_os.sh "$(DEPLOYMENT_ENV)"

# Check workload resources, registry access, Docker, and ZenML registrations.
validate-stack:
	@echo "==> Validating the ZenML remote workload stack"
	@echo "    Configuration: $(DEPLOYMENT_ENV)"
	@if [[ ! -f "$(DEPLOYMENT_ENV)" ]]; then \
		echo "ERROR: Configuration file not found: $(DEPLOYMENT_ENV)" >&2; \
		echo "Create it with: cp deployment.env.example deployment.env" >&2; \
		exit 1; \
	fi
	./scripts/validate_zenml_stack_on_os.sh "$(DEPLOYMENT_ENV)"

# Refresh the existing stack's Kubernetes, registry, and MLflow credentials.
refresh-stack-credentials:
	@echo "==> Refreshing ZenML remote stack credentials"
	@echo "    Configuration: $(DEPLOYMENT_ENV)"
	@if [[ ! -f "$(DEPLOYMENT_ENV)" ]]; then \
		echo "ERROR: Configuration file not found: $(DEPLOYMENT_ENV)" >&2; \
		exit 1; \
	fi
	./scripts/refresh_zenml_stack_credentials_on_os.sh "$(DEPLOYMENT_ENV)"

# Refresh credentials, then evaluate, index, and deploy semantic search.
run-pipeline: refresh-stack-credentials
	@if [[ ! -f "$(DEPLOYMENT_ENV)" ]]; then \
		echo "ERROR: Configuration file not found: $(DEPLOYMENT_ENV)" >&2; \
		exit 1; \
	fi
	set -a; source "$(DEPLOYMENT_ENV)"; set +a; python -m apps.retrieval_poc $(PIPELINE_ARGS)

# Check that the selected KServe search app, UI, and APIs are responding.
validate-model:
	@echo "==> Validating the deployed retrieval search application"
	@echo "    Configuration: $(DEPLOYMENT_ENV)"
	@if [[ ! -f "$(DEPLOYMENT_ENV)" ]]; then \
		echo "ERROR: Configuration file not found: $(DEPLOYMENT_ENV)" >&2; \
		exit 1; \
	fi
	./scripts/validate_retrieval_model_on_os.sh "$(DEPLOYMENT_ENV)"

# Remove phase 2 before phase 1 so its ZenML registrations remain reachable.
delete: delete-stack delete-server

# Remove ZenML stack registrations and the dedicated workload project.
delete-stack:
	@echo "==> Tearing down the ZenML remote workload stack"
	@echo "    Configuration: $(DEPLOYMENT_ENV)"
	@if [[ ! -f "$(DEPLOYMENT_ENV)" ]]; then \
		echo "ERROR: Configuration file not found: $(DEPLOYMENT_ENV)" >&2; \
		exit 1; \
	fi
	./scripts/delete_zenml_stack_on_os.sh "$(DEPLOYMENT_ENV)"

# Remove the ZenML server, Route, persistent MySQL database, and PVCs.
delete-server:
	@echo "==> Tearing down the ZenML server infrastructure"
	@echo "    Configuration: $(DEPLOYMENT_ENV)"
	@if [[ ! -f "$(DEPLOYMENT_ENV)" ]]; then \
		echo "ERROR: Configuration file not found: $(DEPLOYMENT_ENV)" >&2; \
		exit 1; \
	fi
	./scripts/delete_zenml_on_os.sh "$(DEPLOYMENT_ENV)"

helm-lint:
	helm lint deploy/helm/zenml-stack
	helm lint deploy/helm/zenml-server

helm-template:
	helm template zenml-stack deploy/helm/zenml-stack --namespace zenml-workloads \
		-f deploy/helm/zenml-stack/secrets.yaml.example
	helm template zenml-server deploy/helm/zenml-server --namespace zenml \
		-f deploy/helm/zenml-server/values-openshift.yaml \
		-f deploy/helm/zenml-server/secrets.yaml.example

test:
	python -m pytest -q apps/tests
