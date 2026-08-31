#!/usr/bin/env bash

# Structured logging for ZenML OpenShift scripts.
#
# Environment:
#   ZENML_SCRIPT_LOG_LEVEL  Minimum level: DEBUG, INFO, WARN, ERROR (default: INFO)
#   ZENML_SCRIPT_LOG_FILE   Optional path to append timestamped log lines
#   ZENML_SCRIPT_LOG_STDERR When "true", mirror INFO/DEBUG lines to stderr as well

ZENML_SCRIPT_LOG_LEVEL="${ZENML_SCRIPT_LOG_LEVEL:-INFO}"
ZENML_SCRIPT_LOG_LEVEL="$(printf '%s' "${ZENML_SCRIPT_LOG_LEVEL}" | tr '[:lower:]' '[:upper:]')"
SCRIPT_NAME="${SCRIPT_NAME:-unknown-script}"
_SCRIPT_EXIT_HANDLERS=()

_log_level_rank() {
    case "${1}" in
        DEBUG) echo 0 ;;
        INFO) echo 1 ;;
        WARN) echo 2 ;;
        ERROR) echo 3 ;;
        *) echo 1 ;;
    esac
}

_log_level_enabled() {
    local message_level="$1"
    local configured_rank message_rank

    configured_rank="$(_log_level_rank "${ZENML_SCRIPT_LOG_LEVEL}")"
    message_rank="$(_log_level_rank "${message_level}")"
    [[ "${message_rank}" -ge "${configured_rank}" ]]
}

_log_timestamp() {
    date -u +'%Y-%m-%dT%H:%M:%SZ'
}

_log_emit() {
    local level="$1"
    local message="$2"
    local line

    _log_level_enabled "${level}" || return 0

    line="[$(_log_timestamp)] ${level}: [${SCRIPT_NAME}] ${message}"

    if [[ -n "${ZENML_SCRIPT_LOG_FILE:-}" ]]; then
        printf '%s\n' "${line}" >> "${ZENML_SCRIPT_LOG_FILE}"
    fi

    case "${level}" in
        ERROR | WARN)
            printf '%s\n' "${line}" >&2
            ;;
        *)
            if [[ "${ZENML_SCRIPT_LOG_STDERR:-}" == true ]] \
                || [[ "${ZENML_SCRIPT_LOG_LEVEL}" == DEBUG ]]; then
                printf '%s\n' "${line}" >&2
            fi
            ;;
    esac
}

log_debug() {
    _log_emit DEBUG "$*"
}

log_info() {
    _log_emit INFO "$*"
}

log_warn() {
    _log_emit WARN "$*"
}

log_error() {
    _log_emit ERROR "$*"
}

log_section() {
    log_info "==> $*"
}

log_command() {
    log_debug "Running: $*"
}

register_exit_handler() {
    _SCRIPT_EXIT_HANDLERS+=("$1")
}

_run_script_exit_handlers() {
    local exit_code=$?
    local handler

    if ((${#_SCRIPT_EXIT_HANDLERS[@]} > 0)); then
        for handler in "${_SCRIPT_EXIT_HANDLERS[@]}"; do
            [[ -n "${handler}" ]] || continue
            "${handler}" || true
        done
    fi

    if [[ ${exit_code} -eq 0 ]]; then
        log_info "Completed ${SCRIPT_NAME} successfully"
    else
        log_error "Exited ${SCRIPT_NAME} with status ${exit_code}"
    fi

    return "${exit_code}"
}

init_script_logging() {
    local caller_source="${BASH_SOURCE[2]:-${BASH_SOURCE[1]:-${0}}}"

    SCRIPT_NAME="$(basename "${caller_source}")"
    log_info "Starting ${SCRIPT_NAME} (log level: ${ZENML_SCRIPT_LOG_LEVEL})"
    if [[ -n "${ZENML_SCRIPT_LOG_FILE:-}" ]]; then
        log_info "Writing structured logs to ${ZENML_SCRIPT_LOG_FILE}"
    fi

    trap '_run_script_exit_handlers' EXIT
}
