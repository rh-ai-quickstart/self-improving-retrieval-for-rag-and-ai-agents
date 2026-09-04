#!/usr/bin/env bash

validate_model_call_api() {
    section "Calling the deployed search application"
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

    curl --fail --silent --show-error --max-time 10 \
        "http://127.0.0.1:${LOCAL_PORT}/" \
        | grep -Fq "TechQA Semantic Search" \
        || die "Search UI did not return its expected HTML page."

    curl --fail --silent --show-error --max-time 60 \
        -H 'Content-Type: application/json' \
        -d '{"query":"How do I troubleshoot a failed database connection?","top_k":5}' \
        "http://127.0.0.1:${LOCAL_PORT}/search" >"${RESPONSE_FILE}"

    "${ZENML_PYTHON}" - "${RESPONSE_FILE}" "${MODEL_ID}" <<'PY'
import json
import math
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    response = json.load(stream)

if response.get("model_id") != sys.argv[2]:
    raise SystemExit("search response model_id does not match the InferenceService")
results = response.get("results")
if not isinstance(results, list) or not results:
    raise SystemExit("search response contains no results")
for expected_rank, result in enumerate(results, start=1):
    if result.get("rank") != expected_rank:
        raise SystemExit("search results are not sequentially ranked")
    if not result.get("title") or not result.get("snippet"):
        raise SystemExit("search result is missing a title or snippet")
    if not isinstance(result.get("score"), (int, float)) or not math.isfinite(result["score"]):
        raise SystemExit("search result contains an invalid score")

print(f"    OK: Search API returned {len(results)} ranked title/snippet results.")
PY

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
}
