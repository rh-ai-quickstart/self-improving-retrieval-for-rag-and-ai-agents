# Agent guide: Self-improving retrieval for RAG and AI agents

This repository is a **Red Hat Quickstart** for evaluating, selecting, and deploying
embedding models on **Red Hat OpenShift AI** using **ZenML**. It is not a full RAG
application: it covers benchmark preparation, parallel model evaluation, winner
selection, FAISS indexing, and KServe deployment of a working semantic-search UI.

Use this file to orient quickly. Human-facing deployment details live in
[`README.md`](README.md); Python application details live in
[`apps/README.md`](apps/README.md).

## What this project does

1. **Prepare benchmark** — load answerable TechQA development questions and a
   reproducible corpus of IBM Technotes.
2. **Evaluate candidates** — run up to three embedding models in parallel on OpenShift.
3. **Select winner** — choose the model with the best `ndcg_at_10`.
4. **Index** — encode title-plus-body chunks with the winner and store a versioned FAISS bundle in MinIO.
5. **Deploy** — create or update a KServe `InferenceService` and public OpenShift Route exposing the search UI and APIs.

Infrastructure is provisioned in two phases:

| Phase | Command | Deploys |
| --- | --- | --- |
| 1 — ZenML server | `just bootstrap-server` | MySQL, ZenML OSS, OpenShift Route (`deploy/helm/zenml-server/`) |
| 2 — Remote stack | `just bootstrap-stack` | RBAC, KServe permissions, MLflow, MinIO, registry (`deploy/helm/zenml-stack/`) + ZenML registrations |

Phase 1 creates Kubernetes Secret `ZENML_DB_PASSWORD_SECRET` (default
`zenml-db-password`) in `ZENML_NAMESPACE` **before** Helm. Then Helm runs
**two passes**: MySQL only (`zenml.enabled=false`) → wait until Service
`zenml-mysql` and the StatefulSet are Ready → enable ZenML so the
pre-install db-migration Job can resolve DNS. Stuck `pending-*` or
never-deployed `failed` releases are uninstalled so retry works.

After each Helm install, scripts wait in this operational order (Helm `--wait`
still applies to the release as a whole):

**Phase 1 wait/ready:** MySQL-only Helm → MySQL StatefulSet/pod/endpoints →
ZenML Helm (db-migration) → ZenML Deployment → Route → `/health` then `/ready`.

**Phase 2 wait/ready:** project/SA/RBAC `can-i` → KServe Role/RoleBinding →
MLflow Available → MinIO rollout and Route health → MinIO bootstrap Job →
registry → ZenML component registration.

Pipeline execution requires an activated ZenML server, authenticated CLI, bootstrapped
stack, reachable local Docker daemon, and outbound access to Hugging Face.

## Repository map

```
.
├── apps/retrieval_poc/       # Separated pipeline, retrieval, infrastructure, and search-app packages
├── deploy/helm/              # OpenShift Helm charts (zenml-server, zenml-stack)
├── scripts/                  # Bash wrappers; lib/ holds shared helpers
├── deployment.env.example    # Template for deployment.env (copy, chmod 600, customize)
├── justfile / Makefile       # User-facing commands (equivalent targets)
└── docs/images/              # Architecture diagrams referenced by README
```

### Where to change what

| Goal | Primary files |
| --- | --- |
| Add or change embedding candidates | `apps/retrieval_poc/config.py` |
| Change dataset, chunking, metrics, or indexing | `apps/retrieval_poc/retrieval/` |
| Change ZenML steps or pipeline runtime | `apps/retrieval_poc/pipeline/` |
| Change MinIO/KServe/OpenShift adapters | `apps/retrieval_poc/infrastructure/` |
| Change search API or UI | `apps/retrieval_poc/search_app/` |
| Change pipeline CLI/env overrides | `apps/retrieval_poc/__main__.py` |
| Change OpenShift workload infra | `deploy/helm/zenml-stack/` |
| Change ZenML server / MySQL | `deploy/helm/zenml-server/` |
| Change bootstrap, validation, or teardown | `scripts/` and `scripts/lib/` |
| Change deployment defaults | `deployment.env.example` |

## Commands agents should use

Run from the repository root. Prefer `just` (also mirrored in `Makefile`).

```bash
# Setup (human must complete ZenML browser activation between phases 1 and 2)
cp deployment.env.example deployment.env && chmod 600 deployment.env
python -m venv env && source env/bin/activate
pip install -e apps/

just bootstrap-server    # phase 1
# zenml login https://<route-url>
just bootstrap-stack     # phase 2

# Validate without modifying cluster state
just validate
just validate-server
just validate-stack

# Run the example pipeline (refreshes credentials first)
just run-pipeline

# Validate deployed KServe search application
just validate-model

# Teardown (stack first, then server)
just delete
```

Override config file: `DEPLOYMENT_ENV=deployment.lab.env just bootstrap-server`

Helm-only checks (no cluster required for lint):

```bash
make helm-lint
make helm-template
```

There is a retrieval contract test suite under `apps/tests/` and a GitHub Actions
workflow (`.github/workflows/apps-tests.yml`) that runs on pull requests and
pushes to `main` and `dev`. Run `python -m pytest -q apps/tests`, use
`make helm-lint` for chart edits, and, when a cluster is available, use the
`just validate*` and `just run-pipeline` flow.

## Architecture constraints

Keep these in mind before proposing changes:

- **ZenML dynamic pipeline** — candidate evaluations fan out with `.submit()` and
  converge on selection, indexing, and deployment. Max parallel steps default to 3.
- **No committed Dockerfile** — images are built by ZenML at pipeline runtime via
  `DockerSettings` in `pipeline/definition.py`. The same image is reused for
  KServe, started with Uvicorn on `apps.retrieval_poc.search_app.app:app`.
- **Single dependency source** — runtime packages live in `apps/pyproject.toml`;
  do not add a duplicate requirements list to the pipeline definition.
- **Shared chunks** — all candidates and the winning FAISS index use the same
  deterministic title-plus-body word chunks so evaluation matches serving.
- **Versioned bundle** — `index.faiss`, `chunks.json`, and `manifest.json` are
  stored in MinIO under a content digest and downloaded by a KServe init container.
- **Explicit ZenML source root** — `apps/retrieval_poc/__main__.py` sets the
  repository root before importing the pipeline so generated images retain the
  `apps.retrieval_poc` package hierarchy.
- **CPU-only** — PyTorch CPU backend is configured in pipeline Docker settings.
- **Ephemeral pod caches** — Hugging Face and Torch caches use `/tmp` paths.
- **Credential lifetime** — Kubernetes, registry, and MLflow tokens default to 24h.
  `just run-pipeline` refreshes them automatically.
- **POC, not production** — single-replica MinIO/MLflow, SQLite MLflow backend,
  shell-managed secrets, no HA/network-policy hardening. Do not over-engineer for
  production unless explicitly requested.

### ZenML stack components (phase 2)

| Component | Registration name | Backend |
| --- | --- | --- |
| Orchestrator | `openshift-k8s` | Kubernetes in `ZENML_WORKLOAD_NAMESPACE` |
| Artifact store | `openshift-minio` | MinIO PVC + Route |
| Container registry | `openshift-internal` | OpenShift integrated registry |
| Image builder | `openshift-local` | Local Docker on client machine |
| Experiment tracker | `openshift-mlflow` | OpenShift AI MLflow (cluster-scoped) |
| Active stack | `openshift` | Combines the above |

Default namespaces: `zenml` (server), `zenml-workloads` (pipeline pods, MinIO, KServe).

## Coding conventions

### Python (`apps/`)

- **Python 3.11+**, type hints, `from __future__ import annotations`.
- Package layout: import as `apps.retrieval_poc.*` from the repo root.
- ZenML steps live in `pipeline/steps.py`; pure retrieval logic belongs under
  `retrieval/`; cluster/storage adapters belong under `infrastructure/`; FastAPI
  and static assets belong under `search_app/`.
- `@step(enable_cache=False)` for evaluation and deployment; dataset prep may cache.
- Evaluation steps use `runtime="isolated"` and log to MLflow (`experiment_tracker=True`).
- Selection metric default: `ndcg_at_10` in `select_best_model`.
- Keep pipeline parameters wired through `__main__.py` env vars when exposing runtime
  overrides (`NUM_QUERIES`, `CORPUS_SIZE`, `TOP_K`, `SEED`, `QUERY_SPLIT`,
  `MODEL_SERVING_NAME`, `MODEL_SERVING_TIMEOUT`).

When adding a candidate model in `config.py`, set `query_prefix` / `document_prefix`
when the model requires them (see existing BGE and E5 entries).

When changing Docker/runtime behavior, update **both** `pipeline/definition.py`
(`DockerSettings`, `KubernetesOrchestratorSettings`) and, if needed,
`infrastructure/kserve.py` env vars for the KServe container.

### Bash (`scripts/`)

- `set -euo pipefail`; entry scripts set `SCRIPT_DIR` then source `scripts/lib/init.sh`.
- Keep scripts compatible with the macOS system Bash 3.2; do not use namerefs
  (`local -n`) or other Bash 4+ features.
- Shared helpers live under `scripts/lib/` (`logging.sh`, `commands.sh`, `zenml.sh`, etc.).
- Configuration is loaded from `deployment.env` (trusted shell input). Do not commit it.
- Prefer extending existing lib modules over duplicating `oc`/`helm`/`zenml` logic.
- Destructive operations require explicit confirmation (e.g. `ZENML_STACK_DELETE_CONFIRM`).

### Helm (`deploy/helm/`)

- Chart-local secrets: copy `secrets.yaml.example` → `secrets.yaml` (gitignored).
- `zenml-server` includes Bitnami MySQL subchart; pin the image to
  `docker.io/bitnamilegacy/mysql:8.4.3-debian-12-r0` in `values.yaml` and
  `values-openshift.yaml` (`docker.io/bitnami/mysql` versioned tags 404).
  `zenml-stack` provisions MinIO, RBAC, optional MLflow CR, ImageStream,
  registry pull secret templates.
- After chart template changes, run `make helm-lint`.

## Secrets and files never to commit

These are gitignored and must stay local:

- `deployment.env`, `*.local.env`
- `deploy/helm/zenml-server/secrets.yaml`
- `deploy/helm/zenml-stack/secrets.yaml`
- Virtualenvs (`env/`, `.venv/`), `.zen/`, `kube_config`

If a user has local `secrets.yaml` files open, treat contents as sensitive. Prefer
editing `*.example` templates and documenting required values rather than writing
real credentials into tracked files.

## Common agent tasks

### Add a new embedding candidate

1. Add a `ModelConfig` entry in `apps/retrieval_poc/config.py`.
2. If parallelism matters, adjust `PIPELINE_MAX_PARALLEL_STEPS` in `pipeline/definition.py`.
3. Run `just run-pipeline` on a bootstrapped cluster.

### Change benchmark size or random seed

- Prefer env vars (`NUM_QUERIES`, `CORPUS_SIZE`, `SEED`) via `just run-pipeline`.
- Defaults are in `__main__.py` and step signatures under `pipeline/` and `retrieval/`.

### Change the selection metric

- Update `metric=` in `pipeline/definition.py` and ensure `evaluate_model` returns that field.
- `select_best_model` validates presence of the metric across all results.

### Debug a failed pipeline run

1. Check ZenML UI for step logs and artifact lineage.
2. Inspect OpenShift pods in `ZENML_WORKLOAD_NAMESPACE`.
3. Confirm credentials: `just refresh-stack-credentials`.
4. Confirm Docker daemon reachable (`docker info`) for image build/push.
5. For KServe issues, inspect the `InferenceService` named by `MODEL_SERVING_NAME`
   (default `retrieval-embedding`).

### Extend infrastructure

- **Helm-only resources** (MinIO sizing, RBAC, storage class): edit chart templates/values
  and bootstrap scripts if new values must flow from `deployment.env`.
- **ZenML registrations**: changes usually belong in `scripts/lib/bootstrap/zenml_registration.sh`
  and validation under `scripts/lib/validate/stack/`.

## Scope boundaries

Do **not** expand into these unless the user explicitly asks:

- Full RAG stack (ingestion, vector DB, prompt orchestration, answer generation)
- Production HA, secret managers, monitoring, backup/restore
- GPU serving (current design is CPU-only)
- Replacing OpenShift/`oc` with generic Kubernetes unless requested

## Reference versions and platforms

Validated reference environment (see README for full requirements):

- OpenShift AI 3.4.x (tested with 3.4.3)
- OpenShift Container Platform 4.19.9+ through 4.22
- ZenML 0.96.2 (pin with `pip install 'zenml[server]==0.96.2'` for reproduction)
- Python 3.11+

Required local tools: `bash`, `just` or `make`, `oc`, `helm`, `curl`, `openssl`,
Python, Docker CLI + daemon, ZenML CLI.

## Documentation pointers

- Root overview and hardware sizing: [`README.md`](README.md)
- Pipeline, Docker build, serving API: [`apps/README.md`](apps/README.md)
- Server chart: [`deploy/helm/zenml-server/README.md`](deploy/helm/zenml-server/README.md)
- Stack chart: [`deploy/helm/zenml-stack/README.md`](deploy/helm/zenml-stack/README.md)

When editing user-facing docs, keep README and apps/README in sync with behavior
changes. Update this AGENTS.md when conventions, commands, or architecture shift.
