#!/bin/sh
set -u

VM_COMMON_SH="${VM_COMMON_SH:-/usr/libexec/vpn-manager/common.sh}"
VM_RECONCILE_SH="${VM_RECONCILE_SH:-/usr/libexec/vpn-manager/reconcile.sh}"
VM_ROLLBACK_SH="${VM_ROLLBACK_SH:-/usr/libexec/vpn-manager/rollback.sh}"
. "$VM_COMMON_SH"

VM_WORKER_POLL_INTERVAL="${VM_WORKER_POLL_INTERVAL:-1}"
VM_WORKER_DEBOUNCE="${VM_WORKER_DEBOUNCE:-1}"
VM_WORKER_RETRY_DELAY="${VM_WORKER_RETRY_DELAY:-5}"
VM_WORKER_ERROR_DELAY="${VM_WORKER_ERROR_DELAY:-30}"
VM_WORKER_IDLE_RC=200

vm_apply_worker_requeue() {
    local job="$1"
    local rc="$2"

    # Keep the failed job in memory until its retry request is durable. The
    # normal queue priority rules then coalesce it with changes that arrived
    # while reconcile was running (network > full > pbr).
    while ! vm_apply_request "$job" "retry rc=$rc"; do
        vm_job_status_set "$job" error "requeue failed rc=$rc" || true
        sleep "$VM_WORKER_RETRY_DELAY"
    done
    [ "$rc" -eq 75 ] || vm_job_status_set "$job" error "retry queued rc=$rc" || true
}

vm_apply_dedicated_networks_ready() {
    for binding in $(uci -q show "$VM_CFG" 2>/dev/null \
        | sed -n 's/^vpn-manager\.\([^.=]*\)=wifi_binding$/\1/p'); do
        [ "$(uci -q get "$VM_CFG.$binding.enabled")" = "1" ] || continue
        managed_network="$(uci -q get "$VM_CFG.$binding.network")"
        [ -n "$managed_network" ] || return 1
        ubus call "network.interface.$managed_network" status 2>/dev/null \
            | grep -q '"up"[[:space:]]*:[[:space:]]*true' || return 1
    done
    return 0
}

vm_apply_network_reload() {
    require_lan=0
    require_hostapd=0
    ubus call network.interface.lan status 2>/dev/null \
        | grep -q '"up"[[:space:]]*:[[:space:]]*true' && require_lan=1
    [ -z "$(ubus list 'hostapd.*' 2>/dev/null)" ] || require_hostapd=1

    # Netifd must learn the new bridge/interface before hostapd attaches the
    # virtual AP. Reloading WiFi first leaves the SSID without a live network.
    ubus call network reload >/dev/null 2>&1 \
        || /etc/init.d/network reload >/dev/null 2>&1 \
        || return 1
    /etc/init.d/firewall reload >/dev/null 2>&1 || return 1
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || return 1
    wifi reload >/dev/null 2>&1 || return 1

    # A dedicated SSID is never allowed to strand the management plane. Give
    # netifd/hostapd time to settle, then let the caller roll back on failure.
    attempts=0
    while [ "$attempts" -lt 20 ]; do
        management_ready=1
        pidof uhttpd >/dev/null 2>&1 || management_ready=0
        pidof rpcd >/dev/null 2>&1 || management_ready=0
        if [ "$require_lan" = "1" ]; then
            ubus call network.interface.lan status 2>/dev/null \
                | grep -q '"up"[[:space:]]*:[[:space:]]*true' || management_ready=0
        fi
        if [ "$require_hostapd" = "1" ]; then
            [ -n "$(ubus list 'hostapd.*' 2>/dev/null)" ] || management_ready=0
        fi
        vm_apply_dedicated_networks_ready || management_ready=0
        [ "$management_ready" = "0" ] || return 0
        attempts=$((attempts + 1))
        sleep 1
    done
    return 1
}

vm_apply_network_checkpoint_clear() {
    rm -f "$VM_NETWORK_CHANGE_CHECKPOINT"
}

vm_apply_network_rollback() {
    [ -s "$VM_NETWORK_CHANGE_CHECKPOINT" ] || return 1
    rollback_checkpoint="$(cat "$VM_NETWORK_CHANGE_CHECKPOINT" 2>/dev/null || true)"
    [ -n "$rollback_checkpoint" ] || return 1
    if "$VM_ROLLBACK_SH" "$rollback_checkpoint"; then
        vm_apply_network_checkpoint_clear
        vm_log "warn" "unsafe network change rolled back checkpoint=$rollback_checkpoint"
        return 0
    fi
    vm_log "error" "automatic network rollback failed checkpoint=$rollback_checkpoint"
    return 1
}

# Network daemon reloads also mutate the dataplane/config runtime. Serialize
# them in apply -> config order, then release both locks before reconcile.sh;
# reconcile owns its own lock lifecycle and must never inherit ours.
vm_apply_network_prepare() (
    apply_locked=0
    config_locked=0

    cleanup_network_locks() {
        if [ "$config_locked" = "1" ]; then
            vm_config_unlock
            config_locked=0
        fi
        if [ "$apply_locked" = "1" ]; then
            vm_unlock
            apply_locked=0
        fi
    }

    trap cleanup_network_locks EXIT
    trap 'exit 143' HUP INT TERM

    vm_try_lock || exit 75
    apply_locked=1
    vm_config_lock || exit 75
    config_locked=1

    vm_apply_network_reload
)

vm_apply_worker_once() {
    local job mode rc

    job="$(vm_apply_take 2>/dev/null || true)"
    [ -n "$job" ] || return "$VM_WORKER_IDLE_RC"

    case "$job" in
        network)
            vm_job_status_set network running apply || true
            if vm_apply_network_prepare; then
                :
            else
                rc=$?
                if [ "$rc" -eq 75 ]; then
                    vm_log "error" "network prepare busy rc=$rc; retry queued"
                    vm_apply_worker_requeue network "$rc"
                elif vm_apply_network_rollback; then
                    vm_job_status_set network error "unsafe change rolled back rc=$rc" || true
                else
                    vm_log "error" "network prepare failed rc=$rc; rollback unavailable"
                    vm_job_status_set network error "reload failed; rollback unavailable rc=$rc" || true
                fi
                return "$rc"
            fi
            mode="full"
            ;;
        full|pbr)
            mode="$job"
            vm_job_status_set "$job" running apply || true
            ;;
        *)
            vm_log "warn" "apply worker ignored unknown job=$job"
            vm_job_status_set apply error "unknown job: $job" || true
            return 2
            ;;
    esac

    if "$VM_RECONCILE_SH" "$mode"; then
        if [ "$job" = "network" ] && ! vm_apply_dedicated_networks_ready; then
            rc=43
            if vm_apply_network_rollback; then
                vm_job_status_set network error "post-reconcile network check failed; change rolled back" || true
            else
                vm_job_status_set network error "post-reconcile network check failed; rollback unavailable" || true
            fi
            return "$rc"
        fi
        [ "$job" != "network" ] || vm_apply_network_checkpoint_clear
        vm_job_status_set "$job" done applied || true
        return 0
    else
        rc=$?
    fi

    if [ "$job" = "network" ] && vm_apply_network_rollback; then
        vm_job_status_set network error "reconcile failed; change rolled back rc=$rc" || true
        return "$rc"
    fi

    vm_log "error" "apply worker failed job=$job rc=$rc; retry queued"
    vm_apply_worker_requeue "$job" "$rc"
    return "$rc"
}

if [ "${VM_WORKER_SOURCE_ONLY:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

# Boot reconciliation goes through the same coalescing queue as RPC changes.
# If configuration changes arrive while it is running, vm_apply_take returns
# the strongest pending scope on the next pass instead of spawning waiters.
vm_init_dirs
vm_apply_request full startup

while true; do
    # Leave a short coalescing window so a bulk CRUD burst becomes one apply
    # instead of taking config.lock between consecutive API requests.
    if [ -s "$VM_APPLY_QUEUE" ] && [ "$VM_WORKER_DEBOUNCE" -gt 0 ]; then
        vm_queue_wait_quiet "$VM_APPLY_ACTIVITY" "$VM_WORKER_DEBOUNCE"
    fi
    if vm_apply_worker_once; then
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
