#!/usr/bin/env bash

pass() {
    log_info "PASS: $1"
    echo "    PASS: $1"
}

fail() {
    log_error "FAIL: $1"
    echo "    FAIL: $1" >&2
    FAILURES=$((FAILURES + 1))
}

skip() {
    log_info "SKIP: $1"
    echo "    SKIP: $1"
}

command_available() {
    if command -v "$1" >/dev/null 2>&1; then
        pass "Required command available: $1"
        return 0
    fi

    fail "Required command not found: $1"
    return 1
}
