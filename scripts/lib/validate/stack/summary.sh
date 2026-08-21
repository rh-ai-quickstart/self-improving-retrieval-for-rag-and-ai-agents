#!/usr/bin/env bash

validate_stack_print_summary() {
    section "Workload-stack validation summary"
    if [[ "${FAILURES}" -eq 0 ]]; then
        log_info "Validation result: PASS — all workload-stack checks passed."
        success "All workload-stack checks passed."
        exit 0
    fi

    log_error "Validation result: FAIL — ${FAILURES} validation check(s) failed."
    echo "    ${FAILURES} validation check(s) failed." >&2
    echo "    Reconcile the stack with: just bootstrap-stack" >&2
    exit 1
}
