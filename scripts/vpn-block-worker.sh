#!/bin/sh
set -u

VM_COMMON_SH="${VM_COMMON_SH:-/usr/libexec/vpn-manager/common.sh}"
VM_BLOCK_REFRESH_SH="${VM_BLOCK_REFRESH_SH:-/usr/libexec/vpn-manager/block-refresh.sh}"
. "$VM_COMMON_SH"

VM_WORKER_POLL_INTERVAL="${VM_WORKER_POLL_INTERVAL:-1}"
VM_WORKER_DEBOUNCE="${VM_WORKER_DEBOUNCE:-1}"
VM_WORKER_RETRY_DELAY="${VM_WORKER_RETRY_DELAY:-5}"
VM_WORKER_ERROR_DELAY="${VM_WORKER_ERROR_DELAY:-30}"
VM_BLOCK_BACKLOG_DELAY="${VM_BLOCK_BACKLOG_DELAY:-5}"
VM_WORKER_IDLE_RC=200

vm_block_worker_requeue() {
    local rc="$1"

    while ! vm_block_request "retry rc=$rc"; do
        vm_job_status_set block error "requeue failed rc=$rc" || true
        sleep "$VM_WORKER_RETRY_DELAY"
    done
    [ "$rc" -eq 75 ] || vm_job_status_set block error "retry queued rc=$rc" || true
}

vm_block_worker_once() {
    local rc

    vm_block_take >/dev/null 2>&1 || return "$VM_WORKER_IDLE_RC"

    vm_job_status_set block running refresh || true
    if "$VM_BLOCK_REFRESH_SH" --run; then
        vm_job_status_set block done refresh || true
        [ ! -f "$VM_STATE_DIR/block-backlog.pending" ] || sleep "$VM_BLOCK_BACKLOG_DELAY"
        return 0
    else
        rc=$?
    fi

    vm_log "error" "block worker failed rc=$rc; retry queued"
    vm_block_worker_requeue "$rc"
    return "$rc"
}

if [ "${VM_WORKER_SOURCE_ONLY:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

vm_init_dirs

# A restart may have happened after take() removed the durable queue but before
# the failed refresh was requeued. Always scheduling one startup refresh closes
# that crash window; vm_block_take coalesces it with any existing request.
vm_block_request startup

while true; do
    if [ -s "$VM_BLOCK_QUEUE" ] && [ "$VM_WORKER_DEBOUNCE" -gt 0 ]; then
        vm_queue_wait_quiet "$VM_BLOCK_ACTIVITY" "$VM_WORKER_DEBOUNCE"
    fi
    if vm_block_worker_once; then
        continue
    else
        rc=$?
    fi

    if [ "$rc" -eq "$VM_WORKER_IDLE_RC" ]; then
        sleep "$VM_WORKER_POLL_INTERVAL"
    elif [ "$rc" -eq 75 ]; then
        sleep "$VM_WORKER_RETRY_DELAY"
    else
        sleep "$VM_WORKER_ERROR_DELAY"
    fi
done
