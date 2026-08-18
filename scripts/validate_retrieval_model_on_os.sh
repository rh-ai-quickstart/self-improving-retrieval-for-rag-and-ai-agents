#!/usr/bin/env bash
set -euo pipefail

# Read-only validation for the KServe model created by the ZenML pipeline.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${1:-${REPO_ROOT}/deployment.env}"

# shellcheck source=stack_common.sh
source "${SCRIPT_DIR}/stack_common.sh"

PORT_FORWARD_PID=""
RESPONSE_FILE=""
PORT_FORWARD_LOG=""
cleanup() {
    if [[ -n "${PORT_FORWARD_PID}" ]]; then
        kill "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
        wait "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
    fi
    [[ -n "${RESPONSE_FILE}" ]] && rm -f -- "${RESPONSE_FILE}"
    [[ -n "${PORT_FORWARD_LOG}" ]] && rm -f -- "${PORT_FORWARD_LOG}"
}
trap cleanup EXIT

section "Loading model-serving validation configuration"
load_stack_config "${CONFIG_FILE}"
require_command oc
require_command curl
require_command "${ZENML_PYTHON}"

oc whoami >/dev/null 2>&1 \
    || die "The oc CLI is not authenticated to OpenShift."

section "Checking the OpenShift AI KServe deployment"
READY="$(oc get inferenceservice "${MODEL_SERVING_NAME}" \
    -n "${ZENML_WORKLOAD_NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
    2>/dev/null || true)"
[[ "${READY}" == "True" ]] \
    || die "InferenceService ${ZENML_WORKLOAD_NAMESPACE}/${MODEL_SERVING_NAME} is missing or not Ready."

MODEL_ID="$(oc get inferenceservice "${MODEL_SERVING_NAME}" \
    -n "${ZENML_WORKLOAD_NAMESPACE}" \
    -o jsonpath='{.spec.predictor.containers[0].env[?(@.name=="MODEL_ID")].value}')"
[[ -n "${MODEL_ID}" ]] \
    || die "InferenceService ${MODEL_SERVING_NAME} does not declare MODEL_ID."

PREDICTOR_POD="$(oc get pods \
    -n "${ZENML_WORKLOAD_NAMESPACE}" \
    -l "serving.kserve.io/inferenceservice=${MODEL_SERVING_NAME}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "${PREDICTOR_POD}" ]] \
    || die "No running predictor pod was found for InferenceService ${MODEL_SERVING_NAME}."

PREDICTOR_PORT="$(oc get pod "${PREDICTOR_POD}" \
    -n "${ZENML_WORKLOAD_NAMESPACE}" \
    -o jsonpath='{.spec.containers[?(@.name=="kserve-container")].ports[?(@.name=="http1")].containerPort}' \
    2>/dev/null || true)"
[[ "${PREDICTOR_PORT}" =~ ^[1-9][0-9]*$ ]] \
    || die "Predictor pod ${PREDICTOR_POD} does not declare a valid kserve-container/http1 port."

success "InferenceService is Ready with model ${MODEL_ID}."

section "Calling the deployed embedding API"
LOCAL_PORT="${MODEL_SERVING_LOCAL_PORT:-18080}"
[[ "${LOCAL_PORT}" =~ ^[1-9][0-9]*$ ]] \
    || die "MODEL_SERVING_LOCAL_PORT must be a positive port number: ${LOCAL_PORT}"
RESPONSE_FILE="$(mktemp)"
PORT_FORWARD_LOG="$(mktemp)"

oc port-forward \
    -n "${ZENML_WORKLOAD_NAMESPACE}" \
    "pod/${PREDICTOR_POD}" \
    "${LOCAL_PORT}:${PREDICTOR_PORT}" >"${PORT_FORWARD_LOG}" 2>&1 &
PORT_FORWARD_PID=$!

HEALTHY=false
for _ in {1..30}; do
    if curl --fail --silent --max-time 2 \
        "http://127.0.0.1:${LOCAL_PORT}/health" >/dev/null 2>&1; then
        HEALTHY=true
        break
    fi
    if ! kill -0 "${PORT_FORWARD_PID}" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
if [[ "${HEALTHY}" != true ]]; then
    cat "${PORT_FORWARD_LOG}" >&2
    die "Could not reach the KServe predictor through a local port-forward."
fi

curl --fail --silent --show-error --max-time 30 \
    -H 'Content-Type: application/json' \
    -d '{"inputs":["How does dense retrieval work?"],"input_type":"query"}' \
    "http://127.0.0.1:${LOCAL_PORT}/embed" >"${RESPONSE_FILE}"

"${ZENML_PYTHON}" - "${RESPONSE_FILE}" "${MODEL_ID}" <<'PY'
import json
import math
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    response = json.load(stream)

if response.get("model_id") != sys.argv[2]:
    raise SystemExit("response model_id does not match the InferenceService")
embeddings = response.get("embeddings")
if not isinstance(embeddings, list) or len(embeddings) != 1:
    raise SystemExit("response does not contain exactly one embedding")
embedding = embeddings[0]
if not isinstance(embedding, list) or not embedding:
    raise SystemExit("response embedding is empty or invalid")
if not all(isinstance(value, (int, float)) and math.isfinite(value) for value in embedding):
    raise SystemExit("response embedding contains a non-numeric value")

print(f"    OK: Embedding API returned {len(embedding)} dimensions from {response['model_id']}.")
PY

section "Model-serving validation completed"
success "The ZenML-selected model is deployed by OpenShift AI KServe and responding."
