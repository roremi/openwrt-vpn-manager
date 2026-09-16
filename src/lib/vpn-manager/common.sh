#!/bin/sh

VM_STATE_DIR="${VM_STATE_DIR:-/tmp/vpn-manager}"
VM_AUDIT_LOG="${VM_AUDIT_LOG:-/var/log/vpn-manager/audit.log}"
VM_CFG="${VM_CFG:-vpn-manager}"
VM_APPLY_QUEUE="$VM_STATE_DIR/apply.queue"
VM_BLOCK_QUEUE="$VM_STATE_DIR/block.queue"
VM_APPLY_ACTIVITY="$VM_STATE_DIR/apply.activity"
VM_BLOCK_ACTIVITY="$VM_STATE_DIR/block.activity"
VM_APPLY_STATUS="$VM_STATE_DIR/apply-status.json"
VM_BLOCK_STATUS="$VM_STATE_DIR/block-status.json"
VM_NETWORK_CHANGE_CHECKPOINT="$VM_STATE_DIR/network-change.checkpoint"

vm_init_dirs() {
    [ ! -L "$VM_STATE_DIR" ] || rm -f "$VM_STATE_DIR"
    [ ! -L /var/log/vpn-manager ] || rm -f /var/log/vpn-manager
    mkdir -p "$VM_STATE_DIR" /var/log/vpn-manager
    chmod 700 "$VM_STATE_DIR" 2>/dev/null || true
    chmod 700 /var/log/vpn-manager 2>/dev/null || true
    [ ! -f "$VM_AUDIT_LOG" ] || [ -L "$VM_AUDIT_LOG" ] || \
        chmod 600 "$VM_AUDIT_LOG" 2>/dev/null || true
}

vm_now() {
    date +"%Y-%m-%dT%H:%M:%S%z"
}

vm_redact() {
    sed -E 's#((PrivateKey|PresharedKey)[[:space:]]*=[[:space:]]*)[^[:space:]]+#\1***REDACTED***#g; s#("(private_key|preshared_key)"[[:space:]]*:[[:space:]]*")[^"]+#\1***REDACTED***#g; s#((private_key|preshared_key)[[:space:]]*=[[:space:]]*'"'"')[^'"'"']*#\1***REDACTED***#g'
}

vm_log_trim() {
    local file="$1"
    local max_bytes="${2:-524288}"
    local keep_lines="${3:-2000}"
    local size tmp

    [ -f "$file" ] || return 0
    size="$(wc -c < "$file" 2>/dev/null || echo 0)"
    [ "$size" -le "$max_bytes" ] && return 0

    tmp="$file.trim.$$"
    tail -n "$keep_lines" "$file" > "$tmp" 2>/dev/null || {
        rm -f "$tmp"
        return 0
    }
    mv "$tmp" "$file"
}

vm_log() {
    vm_init_dirs
    local level="$1"
    shift
    local msg="$*"
    local safe_msg
    safe_msg="$(printf '%s' "$msg" | vm_redact)"
    vm_log_trim "$VM_AUDIT_LOG" 524288 2000
    [ ! -L "$VM_AUDIT_LOG" ] || rm -f "$VM_AUDIT_LOG"
    ( umask 077; printf '%s level=%s msg="%s"\n' "$(vm_now)" "$level" "$safe_msg" >> "$VM_AUDIT_LOG" )
    chmod 600 "$VM_AUDIT_LOG" 2>/dev/null || true
    logger -t vpn-manager "[$level] $safe_msg"
}

vm_fail() {
    vm_log "error" "$*"
    echo "$*" >&2
    return 1
}

vm_require_cmd() {
    command -v "$1" >/dev/null 2>&1 || vm_fail "missing command: $1"
}

vm_try_lock() {
    vm_init_dirs
    lock -n "$VM_STATE_DIR/apply.lock" 2>/dev/null
}

vm_lock() {
    vm_try_lock || vm_fail "apply already running"
}

vm_unlock() {
    lock -u "$VM_STATE_DIR/apply.lock" 2>/dev/null || true
}

vm_config_lock() {
    vm_init_dirs
    lock -n "$VM_STATE_DIR/config.lock" 2>/dev/null || return 1
}

vm_config_unlock() {
    lock -u "$VM_STATE_DIR/config.lock" 2>/dev/null || true
}

vm_queue_reason() {
    printf '%s' "${1:-unspecified}" | tr '\r\n|\t' '    ' | cut -c1-96
}

vm_queue_lock() {
    local name="$1"

    # Queue critical sections only contain one append or rename. A regular
    # OpenWrt lock closes the writer/taker race without relying on fractional
    # sleep, which is not available on every BusyBox build.
    lock "$VM_STATE_DIR/$name-queue.lock" 2>/dev/null
}

vm_queue_unlock() {
    lock -u "$VM_STATE_DIR/$1-queue.lock" 2>/dev/null || true
}

vm_queue_wait_quiet() {
    local activity_file="$1"
    local quiet_seconds="${2:-1}"
    local last_size current_size stable=0

    case "$quiet_seconds" in
        ''|*[!0-9]*) quiet_seconds=1 ;;
    esac
    [ "$quiet_seconds" -gt 0 ] || return 0
    if [ -f "$activity_file" ]; then
        last_size="$(wc -c < "$activity_file")"
    else
        last_size=0
    fi
    while [ "$stable" -lt "$quiet_seconds" ]; do
        sleep 1
        if [ -f "$activity_file" ]; then
            current_size="$(wc -c < "$activity_file")"
        else
            current_size=0
        fi
        if [ "$current_size" = "$last_size" ]; then
            stable=$((stable + 1))
        else
            stable=0
            last_size="$current_size"
        fi
    done
}

vm_apply_request() {
    local job="${1:-full}"
    local reason

    case "$job" in
        network|full|pbr) : ;;
        *) return 1 ;;
    esac

    vm_init_dirs
    vm_queue_lock apply || return 1
    printf '.' >> "$VM_APPLY_ACTIVITY" || {
        vm_queue_unlock apply
        return 1
    }

    # Keep only the strongest pending scope. Duplicate requests merely update
    # the activity stream used by the quiet-period debounce, making enqueue
    # cost independent of burst size and bounding the durable queue to one row.
    case "$job" in
        network)
            if grep -q '|network|' "$VM_APPLY_QUEUE" 2>/dev/null; then
                vm_queue_unlock apply
                return 0
            fi
            ;;
        full)
            if grep -Eq '\|(network|full)\|' "$VM_APPLY_QUEUE" 2>/dev/null; then
                vm_queue_unlock apply
                return 0
            fi
            ;;
        pbr)
            if grep -Eq '\|(network|full|pbr)\|' "$VM_APPLY_QUEUE" 2>/dev/null; then
                vm_queue_unlock apply
                return 0
            fi
            ;;
    esac

    reason="$(vm_queue_reason "${2:-api}")"
    if ! printf '%s|%s|%s\n' "$(date +%s)" "$job" "$reason" > "$VM_APPLY_QUEUE"; then
        vm_queue_unlock apply
        return 1
    fi
    vm_job_status_set "$job" queued "$reason" || true
    vm_queue_unlock apply
}

vm_apply_take() {
    local batch job

    vm_init_dirs
    vm_queue_lock apply || return 1
    [ -s "$VM_APPLY_QUEUE" ] || {
        vm_queue_unlock apply
        return 1
    }
    batch="$VM_STATE_DIR/apply.batch.$$"
    if ! mv "$VM_APPLY_QUEUE" "$batch" 2>/dev/null; then
        vm_queue_unlock apply
        return 1
    fi
    rm -f "$VM_APPLY_ACTIVITY"
    vm_queue_unlock apply

    if grep -q '|network|' "$batch"; then
        job="network"
    elif grep -q '|full|' "$batch"; then
        job="full"
    else
        job="pbr"
    fi

    rm -f "$batch"
    printf '%s\n' "$job"
}

vm_block_request() {
    local reason
    vm_init_dirs
    vm_queue_lock block || return 1
    printf '.' >> "$VM_BLOCK_ACTIVITY" || {
        vm_queue_unlock block
        return 1
    }
    if grep -q '|block|' "$VM_BLOCK_QUEUE" 2>/dev/null; then
        vm_queue_unlock block
        return 0
    fi
    reason="$(vm_queue_reason "${1:-api}")"
    if ! printf '%s|block|%s\n' "$(date +%s)" "$reason" > "$VM_BLOCK_QUEUE"; then
        vm_queue_unlock block
        return 1
    fi
    vm_job_status_set block queued "$reason" || true
    vm_queue_unlock block
}

vm_block_take() {
    local batch

    vm_init_dirs
    vm_queue_lock block || return 1
    [ -s "$VM_BLOCK_QUEUE" ] || {
        vm_queue_unlock block
        return 1
    }
    batch="$VM_STATE_DIR/block.batch.$$"
    if ! mv "$VM_BLOCK_QUEUE" "$batch" 2>/dev/null; then
        vm_queue_unlock block
        return 1
    fi
    rm -f "$VM_BLOCK_ACTIVITY"
    vm_queue_unlock block
    rm -f "$batch"
    printf '%s\n' block
}

vm_status_detail() {
    printf '%s' "${1:-}" | tr '\r\n\t"\\' '      ' | cut -c1-160
}

vm_job_status_set() {
    local job="${1:-unknown}"
    local state="${2:-idle}"
    local detail file tmp

    vm_init_dirs
    detail="$(vm_status_detail "${3:-}")"
    case "$job" in
        block) file="$VM_BLOCK_STATUS" ;;
        *) file="$VM_APPLY_STATUS" ;;
    esac
    tmp="$file.$$"
    printf '{"job":"%s","state":"%s","updated_at":%s,"detail":"%s"}\n' \
        "$job" "$state" "$(date +%s)" "$detail" > "$tmp"
    mv "$tmp" "$file"
}

vm_status_object() {
    local file="$1"
    local default_job="$2"
    if [ -s "$file" ]; then
        cat "$file"
    else
        printf '{"job":"%s","state":"idle","updated_at":0,"detail":""}' "$default_job"
    fi
}

vm_apply_status_json() {
    local pending="false"
    [ -s "$VM_APPLY_QUEUE" ] && pending="true"
    [ -s "$VM_BLOCK_QUEUE" ] && pending="true"

    printf '{"ok":true,"core":'
    vm_status_object "$VM_APPLY_STATUS" full
    printf ',"block":'
    vm_status_object "$VM_BLOCK_STATUS" block
    printf ',"pending":%s}\n' "$pending"
}
