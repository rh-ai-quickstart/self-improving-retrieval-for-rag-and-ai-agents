#!/usr/bin/env bash

cleanup_files=()

cleanup() {
    local file
    for file in "${cleanup_files[@]:-}"; do
        [[ -z "${file}" ]] && continue
        rm -f -- "${file}"
    done
    return 0
}

setup_cleanup_trap() {
    register_exit_handler cleanup
}

register_stack_cleanup() {
    cleanup() {
        local path
        for path in "${cleanup_files[@]:-}"; do
            [[ -z "${path}" ]] && continue
            if [[ -d "${path}" ]]; then
                rm -f -- "${path}/MINIO_ROOT_USER" "${path}/MINIO_ROOT_PASSWORD"
                rmdir -- "${path}" 2>/dev/null || true
            else
                rm -f -- "${path}"
            fi
        done
    }
    register_exit_handler cleanup
}

register_model_validation_cleanup() {
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
    register_exit_handler cleanup
}
