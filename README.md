# Deploy self-improving retrieval for RAG and AI agents

Evaluate embedding models, index technical-support documentation with the
winner, and deploy a semantic-search UI with ZenML&reg; on Red Hat OpenShift AI&reg;.

## Table of Contents

- [Overview](#overview)
- [Detailed description](#detailed-description)
  - [Architecture diagrams](#architecture-diagrams)
- [Requirements](#requirements)
  - [Minimum hardware requirements](#minimum-hardware-requirements)
  - [Minimum software requirements](#minimum-software-requirements)
  - [Required user permissions](#required-user-permissions)
- [Deploy](#deploy)
  - [Prerequisites](#prerequisites)
  - [Installation](#installation)
  - [Validating the deployment](#validating-the-deployment)
  - [Delete](#delete)
- [Repository structure](#repository-structure)
- [References](#references)
- [Technical details](#technical-details)
  - [Deployed infrastructure](#deployed-infrastructure)
  - [Pipeline execution](#pipeline-execution)
  - [Credential lifetime](#credential-lifetime)
  - [Production-readiness limitations](#production-readiness-limitations)
  - [Why add ZenML to OpenShift AI?](#why-add-zenml-to-openshift-ai)
- [Tags](#tags)

## Detailed description

Technical support engineers at large media and IT services providers must
search thousands of product notes, troubleshooting guides, and known-error
articles while responding to customer incidents. The problems they are
searching may be
described with different product names, symptoms, and technical vocabulary, so
keyword search may miss the most useful document. Slow or inconsistent
retrieval increases resolution time, drives unnecessary escalations, and makes
valuable operational knowledge difficult to reuse.

The business need is therefore broader than putting a search box in front of a
document collection. The organization needs evidence that its chosen retrieval
model works for its own questions and content, plus a repeatable way to promote
a better model and refresh the search experience. Semantic retrieval also forms
the knowledge-access layer that a future RAG assistant or support agent would
use to ground its responses.

Retrieval quality determines whether RAG applications and AI agents receive
useful context before generating an answer or taking an action. This quickstart
demonstrates a repeatable improvement loop that compares embedding models,
selects the strongest candidate, indexes the corpus with that model, and makes
the result immediately testable through a semantic-search UI. It is intended
for teams exploring how retrieval evaluation and deployment can be automated
on OpenShift AI.

By implementing this ZenML-powered self-improving retrieval pipeline, technical support engineers gain faster, more accurate access to the right knowledge articles, even when customers describe problems using different terminology, product names, or symptoms that keyword search would miss. The automated evaluation loop removes guesswork from model selection by benchmarking embedding models against real support queries, so teams can confidently deploy the retrieval approach that actually works best for their content. This translates directly to shorter resolution times, fewer unnecessary escalations, and better reuse of hard-won operational knowledge. Because the pipeline is repeatable and observable, retrieval quality improves over time rather than degrading as documentation grows, and the same semantic search layer becomes the ready-made foundation for a future RAG assistant or AI-powered support agent.

### Architecture diagrams

The component view separates the shared OpenShift capabilities, OpenShift
AI-managed services, ZenML control plane, POC workloads, developer workstation,
and external software and model sources used by the example.

![High-level component architecture for the self-improving retrieval POC](docs/images/high_level_architecture_diagram.png)

*High-level component architecture and deployment boundaries.*


## Requirements

Before deploying, confirm the available cluster capacity, supported platform
components, local tooling, and required OpenShift permissions described below.

### Minimum hardware requirements

| Node Type     | Qty | vCPU | Memory (GB) |
|---------------|-----|------|-------------|
| Control Plane | 3   | 8    | 16          |
| Worker        | 2   | 8    | 32          |

**NOTE**: A GPU is not required for this quickstart

### Minimum software requirements

**Target platform versions:**

- Red Hat OpenShift AI `3.4` or later; this POC was tested with `3.4.3`.
- Red Hat OpenShift Container Platform `4.20` or later

**Required cluster services:**

- Dynamic persistent storage and a default `StorageClass` for MySQL.
- OpenShift AI KServe and MLflow Operator components in the `Managed` state.
- The KServe `InferenceService` and OpenShift AI `MLflow` custom resources.
- The OpenShift integrated image registry in the `Managed` state.
- Storage classes for MinIO and MLflow. Both default to `gp3-csi` and can be
  changed in `deployment.env`.

**Local tools:**

- Bash (including the macOS system Bash 3.2) and `just`.
- Python `3.11` or newer.
- `oc`, authenticated to the target OpenShift cluster.
- Helm 3.
- `curl` and `openssl`.
- A running local Docker daemon, the Docker CLI, and the Docker Python SDK.
- A ZenML client version selected from the
  [ZenML release history on PyPI](https://pypi.org/project/zenml/#history).
  The scripts deploy the matching server version automatically. This POC was
  validated with `0.96.2`; newer versions may require compatibility changes.

The client and cluster also need outbound access to the configured container
registries, the ZenML Helm chart, Python package indexes, Hugging Face model and
dataset repositories, and the OpenShift Routes created by this project.

### Required user permissions

Run the bootstrap as a cluster administrator, or as a user with an equivalent
set of permissions. The scripts need permission to:

- Create the `zenml` and `zenml-workloads` projects.
- Read storage classes, OpenShift templates, custom resource definitions, the
  `DataScienceCluster`, and cluster roles.
- Use `oc adm policy` to grant roles to the orchestrator service account.
- Create and bind namespace roles for KServe and MLflow access.
- Create a cluster-scoped OpenShift AI `MLflow` resource when one is absent.
- Patch the cluster image-registry configuration to enable its default Route.
- Create deployments, services, routes, secrets, jobs, PVCs, image streams, and
  KServe `InferenceService` resources.

The current bootstrap is not suitable for a user restricted to a single
pre-provisioned namespace.


## Deploy

Deployment proceeds in two phases: provision the ZenML server and MySQL, then
configure the remote workload stack and OpenShift AI integrations. Validation
and cleanup commands follow the installation steps.

### Prerequisites

From the repository root, create a Python environment and install the project
dependencies:

```bash
python -m venv env
source env/bin/activate
python -m pip install --upgrade pip
python -m pip install -e apps/
```

The unpinned project dependency installs the newest ZenML release compatible
with the local Python environment. To reproduce this POC with its validated
version, install it explicitly before installing the project:

```bash
python -m pip install 'zenml[server]==0.96.2'
python -m pip install -e apps/
```

`just bootstrap-stack` installs the S3 and MLflow integrations through
`zenml integration install s3 mlflow -y`. ZenML therefore controls the client
dependency sets used for the MinIO artifact store and MLflow experiment
tracking.

Confirm that `oc` is authenticated and that the local Docker daemon is
reachable:

```bash
oc whoami
docker info
```

The scripts use the interpreter configured by `ZENML_PYTHON`. Set it in the
deployment configuration if `python` does not resolve to the environment
created above.

### Installation

Deployment has two phases because the ZenML server must be activated and the
local CLI authenticated before the remote stack can be registered.

1. Copy and protect the deployment configuration:

   ```bash
   cp deployment.env.example deployment.env
   chmod 600 deployment.env
   ```

   Review the namespace names, storage classes, storage sizes, and token
   durations. The scripts treat this file as trusted input and load it as shell
   configuration.

2. Deploy the ZenML server and its persistent MySQL database:

   ```bash
   just bootstrap-server
   ```

3. Open the ZenML Route printed by the command and complete the initial browser
   activation. Then authenticate the local ZenML CLI:

   ```bash
   zenml login https://ZENML_ROUTE
   zenml status
   ```

4. With the local Docker daemon running, deploy and register the remote
   OpenShift workload stack:

   ```bash
   just bootstrap-stack
   ```

To use a configuration other than `deployment.env`, pass it to any recipe
through `DEPLOYMENT_ENV`:

```bash
DEPLOYMENT_ENV=deployment.lab.env just bootstrap-server
```

### Validating the deployment

First, validate both infrastructure deployment phases:

```bash
just validate
```

The validation checks the server, routes, persistent storage, workload
permissions, registry access, Docker connectivity, OpenShift AI components, and
ZenML registrations without intentionally modifying them.

Then execute the example pipeline:

```bash
just run-pipeline
```

For a quick end-to-end check before running the larger benchmark:

```bash
just run-pipeline --smoke
```

This smoke profile uses 20 queries, 40 documents, and `top_k=20`—two
corpus-encoding batches per candidate with the current seed and chunking
defaults. It overrides the three corresponding environment settings for that
submission only. Use `make run-pipeline PIPELINE_ARGS=--smoke` when using Make.

The command refreshes the short-lived stack credentials, builds and pushes the
pipeline image, and submits the run to the OpenShift-backed ZenML stack. The
pipeline evaluates its configured embedding candidates, records the experiment
in MLflow, selects a winner, builds and stores a FAISS search bundle in MinIO,
then deploys it as a KServe `InferenceService` with an OpenShift Route. The
final ZenML step and pipeline-run metadata contain a clickable link to the UI.

### Opening the search UI

The search UI is exposed by an OpenShift Route named `{MODEL_SERVING_NAME}-ui`
(default `retrieval-embedding-ui`), not the InferenceService name
(`retrieval-embedding`). KServe on OpenShift removes Routes that share the
InferenceService name, so the pipeline creates the `-ui` Route deliberately.

After the pipeline completes, open its run in the ZenML dashboard, select the
`deploy_search_app` step, and open **Run Insights → Metadata**. The deployment
publishes three URI values:

- `search_ui` opens the browser search interface.
- `search_api_docs` opens the interactive FastAPI documentation.
- `health_endpoint` returns the deployment readiness information.

![ZenML deployment-step metadata containing links to the search UI, API documentation, and health endpoint](docs/images/zenml_search_app_metadata.png)

*Select `deploy_search_app`, open the Metadata tab, and click `search_ui`.*

Metadata links from older pipeline runs may still point at
`retrieval-embedding-...` hostnames that no longer resolve. Use the latest run
or run `just validate-model` to print the admitted Route URL.

The public OpenShift Route opens a small search application. Enter a support
question, choose the number of results, and select **Search**. Each result shows
its rank, document title, matching text snippet, similarity score, source
document, and chunk number. The header above the results also identifies the
winning embedding model and request latency.

![Technical-support semantic search UI showing ranked IBM Technote results](docs/images/technical_support_search_ui.png)

*The winner-indexed search application returning the relevant ITCAM for
DataPower Technote.*

The search UI is published on an OpenShift Route named `{MODEL_SERVING_NAME}-ui`
(default `retrieval-embedding-ui`), not the KServe `InferenceService` name
(`retrieval-embedding`). KServe on OpenShift removes Routes that share the
InferenceService name, so the deploy step uses a separate `-ui` Route. ZenML
metadata links from older pipeline runs may still point at the previous Route
name and will not load; use the latest run metadata or `just validate-model` for
the current URL.

If the ZenML link is unavailable, `just validate-model` validates the
deployment and prints the complete public Route URL. The command requires an
authenticated `oc` session and uses `MODEL_SERVING_ROUTE` (and related settings)
from `deployment.env`.

Finally, validate the deployed search application:

```bash
just validate-model
```

This checks that the `InferenceService` and Route are ready, forwards a local
port directly to the predictor pod, loads the HTML UI, submits a query to
`/search`, and verifies `/embed` as well. The command prints the public UI URL.

Individual checks and operational commands are also available:

| Command | Result |
| --- | --- |
| `just validate-server` | Validates the ZenML server and MySQL deployment |
| `just validate-stack` | Validates OpenShift resources and ZenML stack registrations |
| `just refresh-stack-credentials` | Renews Kubernetes, registry, and MLflow credentials |
| `just run-pipeline` | Refreshes credentials and submits the configured pipeline |
| `just run-pipeline --smoke` | Refreshes credentials and submits the small smoke profile |
| `just validate-model` | Checks the KServe search UI, ranked results, and embedding API |

### Delete

Remove the remote stack before the server so that the teardown can still
authenticate to ZenML and delete its component registrations:

```bash
just delete
```

Deletion requires explicit confirmation. It removes the dedicated workload
project, including MinIO artifacts, pipeline images, and its PVC, and then
removes the ZenML server, MySQL database, and their PVCs.

The shared cluster-scoped MLflow instance and the integrated registry's default
Route are intentionally retained and must be reviewed separately.

The phases can also be removed individually, in this order:

```bash
just delete-stack
just delete-server
```


## Repository structure

```
.
├── apps/
│   ├── pyproject.toml        # Python package and dependency metadata
│   ├── .dockerignore         # Docker build exclusions for pipeline images
│   ├── tests/                # Retrieval/index/search contract tests
│   └── retrieval_poc/
│       ├── pipeline/         # Dynamic ZenML definition and decorated steps
│       ├── retrieval/        # Dataset, chunking, metrics, and FAISS bundle
│       ├── infrastructure/   # MinIO and KServe/OpenShift adapters
│       ├── search_app/       # FastAPI API and static browser UI
│       └── __main__.py       # Pipeline entry point (`python -m apps.retrieval_poc`)
├── deploy/
│   └── helm/
│       ├── zenml-server/     # Umbrella chart: ZenML + Bitnami MySQL + Route
│       └── zenml-stack/      # Workload chart: MinIO, RBAC, MLflow, registry
├── scripts/                  # Thin wrappers around Helm, ZenML CLI, and validation
├── docs/images/              # Architecture diagrams and screenshots
├── deployment.env.example    # Deployment and stack configuration example
├── justfile                  # User-facing deployment and operation commands
└── README.md
```

Phase 1 installs the [`deploy/helm/zenml-server/`](deploy/helm/zenml-server/)
umbrella chart (upstream ZenML, Bitnami MySQL, OpenShift Route), then waits for
MySQL, the ZenML Deployment, the Route, and `/health`. Phase 2 installs
[`deploy/helm/zenml-stack/`](deploy/helm/zenml-stack/), waits for MLflow then
MinIO, and registers ZenML components with the local CLI.

## References

- [ZenML documentation](https://docs.zenml.io/)
- [ZenML releases on PyPI](https://pypi.org/project/zenml/#history)
- [Red Hat OpenShift AI Self-Managed 3.4 documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4)
- [Red Hat OpenShift AI 3.x supported configurations](https://access.redhat.com/articles/rhoai-supported-configs-3.x)
- [KServe documentation](https://kserve.github.io/website/)
- [MLflow documentation](https://www.mlflow.org/docs/latest/)
- [TechQA-RAG-Eval dataset on Hugging Face](https://huggingface.co/datasets/nvidia/TechQA-RAG-Eval)
- [Original TechQA dataset paper](https://aclanthology.org/2020.acl-main.117/)
- [IBM Research TechQA publication](https://research.ibm.com/publications/the-techqa-dataset)

## Technical details

ZenML is an open-source MLOps framework for building portable ML workflows in
Python. Its stack abstraction separates pipeline code from the infrastructure
that executes it, allowing the same workflow to move between local and remote
orchestrators and interchangeable services for artifacts, images, and
experiment tracking. This example also uses ZenML's experimental
dynamic-pipeline API: native Python loops and conditionals construct the runtime
graph, while candidate evaluations are submitted as concurrent, isolated steps.
ZenML records the resulting runs, step states, and artifact metadata in one
observable workflow.

### Deployed infrastructure

The scripts provision the infrastructure in two phases.

**ZenML server project (`zenml` by default):**

- The selected ZenML OSS version via the `zenml-server` umbrella Helm chart.
  Version `0.96.2` is the reference version used to validate this POC.
- A persistent MySQL database from the Bitnami MySQL subchart, using
  `docker.io/bitnamilegacy/mysql:8.4.3-debian-12-r0` (the versioned
  `docker.io/bitnami/mysql` tags were moved off Docker Hub).
- Database credential Secrets and a `5Gi` PVC by default.
- An edge-terminated OpenShift Route for the ZenML server.

After Helm install, the Phase 1 script waits for MySQL, then the ZenML
Deployment, then the Route and `/health`.

**Remote workload project (`zenml-workloads` by default):**

| ZenML component | Implementation |
| --- | --- |
| Orchestrator | Kubernetes workloads running under a dedicated service account |
| Artifact store | Single-replica MinIO with a persistent bucket |
| Container registry | OpenShift integrated image registry |
| Image builder | Local Docker builder on the client machine |
| Experiment tracker | OpenShift AI MLflow |
| Model serving | OpenShift AI KServe |

The remote-stack bootstrap installs the `zenml-stack` Helm chart (service
account, RBAC, KServe permissions, MLflow, MinIO, and registry templates), then
waits in this order: project/SA/RBAC, KServe Role/RoleBinding, MLflow Available,
MinIO rollout and Route health, MinIO bucket bootstrap Job, integrated registry
Route, and ZenML component registration as the active stack.

MLflow is cluster-scoped. An existing configured instance is reused; otherwise,
the chart creates a single-replica instance backed by SQLite and a `10Gi`
PVC. The KServe `InferenceService` is created later by the pipeline rather
than during infrastructure bootstrap.

### Pipeline execution

The example implements a compact evaluate-select-deploy loop for an embedding
model used by a retrieval system:

![Embedding model evaluation and deployment workflow](docs/images/execution_diagram.png)

*How the pipeline uses ZenML, OpenShift AI, and the supporting services.*

1. Prepare a reproducible TechQA technical-support retrieval benchmark.
2. Evaluate the configured embedding candidates in parallel on OpenShift.
3. Store pipeline artifacts in MinIO and experiment results in MLflow.
4. Select the strongest candidate according to the pipeline's retrieval-quality
   criterion.
5. Re-encode title-plus-body chunks with the winner and persist a versioned
   FAISS search bundle in MinIO.
6. Create or update a CPU-based KServe `InferenceService`, expose its FastAPI UI
   through an OpenShift Route, and publish clickable URLs in ZenML metadata.

The deployed service exposes `/` for the search UI, `/search` for ranked
document results, `/health` for readiness, `/embed` for embeddings, and `/docs`
for its OpenAPI UI. This POC demonstrates automated improvement and delivery of
a retrieval component; it does not implement a complete generative RAG system.

The ZenML UI exposes both a run timeline and the underlying step graph. In the
reference run below, the three candidate evaluations execute independently
before their results converge on model selection and deployment.

![Completed ZenML pipeline run and parallel step timeline](docs/images/run_overview_1.png)

*Completed pipeline run with parallel candidate evaluations.*

![ZenML pipeline graph showing step inputs, outputs, and dependencies](docs/images/run_overview_2.png)

*Pipeline graph for benchmark preparation, candidate evaluation, model
selection, and deployment.*

### Credential lifetime

The Kubernetes connector, registry pull secret, and MLflow tracking token use
OpenShift service-account tokens. Their requested lifetime defaults to 24 hours,
with a five-minute expiry safety window for the Kubernetes connector.

`just run-pipeline` refreshes these credentials before submission. They can be
renewed independently with:

```bash
just refresh-stack-credentials
```

Refresh requires authenticated `oc` and ZenML CLI sessions and a reachable
local Docker daemon.

### Production-readiness limitations

**WARNING**
This deployment is a proof of concept. It is intended for isolated development and demonstration environments, not production use.

The included search application is intentionally a small-scale POC: it loads a
static, exact FAISS `IndexFlatIP` index into the FastAPI process and rebuilds
that index through the pipeline rather than supporting continuous ingestion.
A production information-retrieval system would normally separate the serving
API from a durable, replicated search or vector service, use an appropriate
approximate-nearest-neighbor strategy for corpus size and latency targets, and
add incremental indexing, metadata filtering, access control, observability,
capacity planning, and controlled index rollouts. The UI demonstrates the
evaluated model and indexed content; it is not intended as a production search
platform.

Current limitations include:

- ZenML, MySQL, MinIO, MLflow, and model serving are not configured for high
  availability or multi-zone failure tolerance.
- MinIO and MLflow are single-replica deployments; MLflow uses SQLite and local
  persistent-volume storage.
- Local shell scripts create and rotate secrets and short-lived tokens. There
  is no external secret manager or in-cluster credential rotation.
- The integrated image registry's default Route is enabled cluster-wide.
- This repository does not install network policies or manage Route
  certificates and external identity-provider integration.
- Quotas, autoscaling, pod disruption budgets, capacity testing, monitoring,
  alerting, and backup and restore procedures are not provided.

A production adaptation should use supported highly available stateful
services, managed secrets, least-privilege bootstrap identities, restricted
network exposure, and defined backup, observability, upgrade, and recovery
procedures.

The implementation presents self-improvement as a bounded, observable ZenML
loop over the TechQA benchmark and IBM Technotes. Teams can adapt the same
pattern to their own support queries and documentation.

The benchmark uses NVIDIA's Apache-2.0 TechQA-RAG-Eval packaging of the original
IBM TechQA dataset. It contains 910 questions (600 train and 310 development),
of which 610 are answerable and 300 intentionally unanswerable. The default
retrieval evaluation uses all 160 answerable development questions against the
496 unique Technotes referenced by the answerable dataset rows. Unanswerable
questions have no relevance judgments, so they are not included in retrieval
metrics.

### Why add ZenML to OpenShift AI?

This quickstart uses OpenShift AI as its workload and model-serving platform
and ZenML as its ML workflow abstraction and control plane. To understand what
ZenML adds, why this architecture uses it instead of the KFP-based OpenShift AI
Pipelines service, and which teams benefit from the combination, see
[Why add ZenML to Red Hat OpenShift AI?](docs/why-zenml-on-openshift-ai.md).


## Tags

- **Title:** Depoloy self-improving retrieval for RAG and AI agents
- **Description:** Evaluate embedding models and deploy winner-indexed technical-support search with ZenML on Red Hat OpenShift AI.
- **Industry:** Media and IT Services
- **Product:** OpenShift AI
- **Use case:** Semantic search over enterprise technical-support documentation
- **Partner:** ZenML
- **Contributor org:** Red Hat
