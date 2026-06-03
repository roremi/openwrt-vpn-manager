#!/bin/sh

VM_STATE_DIR="/tmp/vpn-manager"
VM_AUDIT_LOG="/var/log/vpn-manager/audit.log"
VM_CFG="vpn-manager"

vm_init_dirs() {
    mkdir -p "$VM_STATE_DIR" /var/log/vpn-manager
}

vm_now() {
    date +"%Y-%m-%dT%H:%M:%S%z"
}

vm_redact() {
    sed -E 's#(PrivateKey[[:space:]]*=[[:space:]]*)[^[:space:]]+#\1***REDACTED***#g; s#("private_key"[[:space:]]*:[[:space:]]*")[^"]+#\1***REDACTED***#g'
}

vm_log() {
    vm_init_dirs
    local level="$1"
    shift
    local msg="$*"
    printf '%s level=%s msg="%s"\n' "$(vm_now)" "$level" "$msg" | vm_redact >> "$VM_AUDIT_LOG"
    logger -t vpn-manager "[$level] $msg"
}

vm_fail() {
    vm_log "error" "$*"
    echo "$*" >&2
    return 1
}

vm_require_cmd() {
    command -v "$1" >/dev/null 2>&1 || vm_fail "missing command: $1"
}

vm_lock() {
    vm_init_dirs
    local t=0
    while ! lock "$VM_STATE_DIR/lock" 2>/dev/null; do
        t=$((t + 1))
        [ "$t" -ge 30 ] && vm_fail "unable to acquire lock"
        sleep 1
    done
}

vm_unlock() {
    lock -u "$VM_STATE_DIR/lock" 2>/dev/null
}
