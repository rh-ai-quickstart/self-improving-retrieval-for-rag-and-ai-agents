# Retrieval model selection application

This package implements a ZenML pipeline that evaluates embedding models on the
BEIR SciFact benchmark, selects the best candidate for dense retrieval, and
deploys it to OpenShift AI KServe. It is the Python application at the center of
the repository's self-improving retrieval proof of concept.

The pipeline does not implement a full RAG stack. It focuses on the retrieval
component: benchmark preparation, parallel model evaluation, winner selection,
and serving the chosen model through a small embedding HTTP API.

## Layout

```
apps/
├── pyproject.toml          # Package metadata and dependencies
├── .dockerignore           # Exclusions for ZenML-generated container builds
└── retrieval_poc/
    ├── __main__.py         # Entry point: python -m apps.retrieval_poc
    ├── pipeline.py         # ZenML pipeline definition and runtime settings
    ├── steps.py            # Dataset, evaluation, and selection steps
    ├── deployment.py       # KServe InferenceService deployment step
    ├── server.py           # FastAPI embedding service (/health, /embed)
    ├── config.py           # Candidate embedding models
    ├── dataset.py          # SciFact benchmark loading
    └── evaluation.py       # Retrieval metrics (for example nDCG@10)
```

Run the pipeline from the repository root after bootstrapping the ZenML server
and remote stack:

```bash
make run-pipeline
# or: just run-pipeline
```

That refreshes stack credentials and submits `python -m apps.retrieval_poc`.

## Pipeline flow

1. **Prepare benchmark** — load a reproducible SciFact subset once as a shared
   artifact.
2. **Evaluate candidates** — run up to three embedding models in parallel on
   OpenShift; log metrics to MLflow.
3. **Select winner** — pick the model with the best `ndcg_at_10` score.
4. **Deploy** — create or update a KServe `InferenceService` that serves the
   winning model through `server.py`.

Default candidates are defined in `retrieval_poc/config.py`:

- `sentence-transformers/all-MiniLM-L6-v2`
- `BAAI/bge-small-en-v1.5`
- `intfloat/e5-small-v2`

## Container images

There is **no committed `Dockerfile`** in this repository. Container images are
built by ZenML at pipeline runtime using the local image builder registered
during stack bootstrap (`openshift-local`, flavor `local`).

Build behavior is declared in `retrieval_poc/pipeline.py` through
`DockerSettings`:

- **Requirements** — step dependencies such as `sentence-transformers`, `torch`,
  and `fastapi`.
- **Project install** — `pyproject_path="apps/pyproject.toml"` and
  `local_project_install_command="uv pip install --no-deps ./apps"` so
  `apps.retrieval_poc` is importable inside the image.
- **CPU PyTorch** — `python_package_installer_args={"torch-backend": "cpu"}`.
- **Runtime caches** — Hugging Face and Torch cache paths under `/tmp` for
  ephemeral OpenShift pods.
- **Docker ignore** — `DockerBuildConfig(dockerignore="apps/.dockerignore")`.

ZenML generates the underlying Dockerfile, builds the image with your local
Docker daemon, and pushes it to the OpenShift integrated registry configured in
the active ZenML stack. The deployment step reuses that same image for the
KServe predictor, which starts Uvicorn directly rather than through ZenML's
normal step entrypoint. Installing the local project in the image is what makes
`apps.retrieval_poc.server` available in both execution modes.

### `apps/.dockerignore`

This file keeps secrets, local virtual environments, and repository metadata out
of pipeline images. It is referenced by the pipeline's `DockerBuildConfig`, not
by a hand-written Dockerfile.

Typical exclusions include `deployment.env`, `.venv`, `__pycache__`, `.zen`,
and `.git`.

## Serving API

After deployment, the KServe model exposes:

| Endpoint   | Purpose                                      |
| ---------- | ---------------------------------------------- |
| `/health`  | Readiness check used by validation scripts     |
| `/embed`   | Returns embeddings for query or document text |

The server reads `MODEL_ID` from the environment and optional prefix settings
for models that require query/document formatting.

Validate a deployed model from the repository root:

```bash
make validate-model
```

## Configuration

Pipeline parameters can be overridden with environment variables when submitting
the run (see `retrieval_poc/__main__.py`):

| Variable               | Default               | Description                    |
| ---------------------- | --------------------- | ------------------------------ |
| `NUM_QUERIES`          | `200`                 | Benchmark query count          |
| `CORPUS_SIZE`          | `2500`                | Benchmark corpus size          |
| `TOP_K`                | `50`                  | Retrieval depth for evaluation |
| `SEED`                 | `42`                  | Random seed                    |
| `MODEL_SERVING_NAME`   | `retrieval-embedding` | KServe InferenceService name   |
| `MODEL_SERVING_TIMEOUT`| `600`                 | Deployment wait timeout (s)    |

Infrastructure settings (namespaces, stack components, storage, and credentials)
live in the repository-root `deployment.env`, not in this package.

## Local development

Install the package in a virtual environment from the repository root:

```bash
python -m venv .venv
source .venv/bin/activate
pip install -e ./apps
```

You still need an activated ZenML server, authenticated CLI, and bootstrapped
remote stack before submitting pipeline runs. See the root `README.md` for the
full OpenShift bootstrap workflow.
