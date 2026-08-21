#!/usr/bin/env bash

section() {
    log_section "$1"
    echo
    echo "======================================================================"
    echo "==> $1"
    echo "======================================================================"
}

info() {
    log_info "$1"
    echo "    $1"
}

success() {
    log_info "OK: $1"
    echo "    OK: $1"
}

warn() {
    log_warn "$1"
    echo "    WARNING: $1" >&2
}

die() {
    log_error "$1"
    echo >&2
    echo "ERROR: $1" >&2
    exit 1
}
