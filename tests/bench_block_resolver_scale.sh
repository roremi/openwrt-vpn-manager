#!/bin/sh
set -eu

VM_LIB_DIR="${VM_BENCH_LIB_DIR:-/tmp/vm-block-scale/lib}"
VM_STATE_DIR="${VM_BENCH_STATE_DIR:-/tmp/vm-block-scale/state}"
VM_AUDIT_LOG="$VM_STATE_DIR/audit.log"
VM_BLOCK_QUERY_TIMEOUT=5
VM_BLOCK_RESOLVE_WORKERS=6
VM_BLOCK_REFRESH_BUDGET=1
VM_BLOCK_FAILURE_RETRY=60
VM_BLOCK_CACHE_TTL=1800
VM_BENCH_TRACE="$VM_STATE_DIR/nslookup.trace"
VM_BENCH_FIRST_DNS="$VM_STATE_DIR/first-dns"
VM_BLOCK_PHASE_TRACE="$VM_STATE_DIR/phases"

export VM_LIB_DIR VM_STATE_DIR VM_AUDIT_LOG VM_BLOCK_QUERY_TIMEOUT
export VM_BLOCK_RESOLVE_WORKERS VM_BLOCK_REFRESH_BUDGET
export VM_BLOCK_FAILURE_RETRY VM_BLOCK_CACHE_TTL
export VM_BENCH_TRACE VM_BENCH_FIRST_DNS VM_BLOCK_PHASE_TRACE

case "$VM_STATE_DIR" in
    /tmp/vm-block-scale/*) ;;
    *) echo "unsafe benchmark state: $VM_STATE_DIR" >&2; exit 2 ;;
esac
rm -rf "$VM_STATE_DIR"
mkdir -p "$VM_STATE_DIR"

. "$VM_LIB_DIR/pbr.sh"

vm_pbr_block_snapshot_config() {
    : > "$1"
    awk 'BEGIN { for (i=1; i<=100; i++) printf "10.0.0.%d\n", i }' > "$2"
    awk 'BEGIN { for (i=1; i<=100; i++) printf "d%03d.example|wildcard\n", i }' > "$3"
}

nslookup() {
    if mkdir "$VM_STATE_DIR/first-dns-lock" 2>/dev/null; then
        date +%s > "$VM_BENCH_FIRST_DNS"
        wc -l "$VM_STATE_DIR"/block-build.*/tasks > "$VM_STATE_DIR/task-count"
        awk -F '|' '!seen[$1 FS $2 FS $3]++ { count++ } END { print count + 0 }' \
            "$VM_STATE_DIR/block-cache/v2-compact/active.tsv" > "$VM_STATE_DIR/pair-count"
    fi
    printf '%s|%s\n' "$1" "$2" >> "$VM_BENCH_TRACE"
    if [ "${VM_BENCH_DNS_SUCCESS:-0}" = "1" ]; then
        printf 'Server: %s\nAddress 1: %s\n\nName: %s\nAddress 1: 203.0.113.20\n' \
            "$2" "$2" "$1"
        return 0
    fi
    sleep 10
}

baseline="$(ps | wc -l | tr -d ' ')"
start="$(date +%s)"
vm_pbr_generate_block &
generate_pid=$!
peak="$baseline"
while kill -0 "$generate_pid" 2>/dev/null; do
    current="$(ps | wc -l | tr -d ' ')"
    [ "$current" -le "$peak" ] || peak="$current"
    sleep 1
done
wait "$generate_pid"
finish="$(date +%s)"

first_dns="$(cat "$VM_BENCH_FIRST_DNS" 2>/dev/null || echo "$finish")"
pair_count="$(awk '{print $1}' "$VM_STATE_DIR/pair-count" 2>/dev/null || true)"
task_count="$(awk '{print $1}' "$VM_STATE_DIR/task-count" 2>/dev/null || true)"
[ -n "$pair_count" ] || pair_count="$(wc -l < "$VM_STATE_DIR/block-cache/v2-compact/active.tsv" | tr -d ' ')"
[ -n "$task_count" ] || task_count="$(awk -F '|' '{ count += ($2 == "exact" ? 1 : 8) } END { print count + 0 }' "$VM_STATE_DIR/block-cache/v2-compact/active.tsv")"
if [ -f "$VM_BENCH_TRACE" ]; then
    lookup_count="$(wc -l < "$VM_BENCH_TRACE" | tr -d ' ')"
else
    lookup_count=0
fi
cache_files="$(find "$VM_STATE_DIR/block-cache" -type f 2>/dev/null | wc -l | tr -d ' ')"
cache_bytes="$(du -sk "$VM_STATE_DIR/block-cache" 2>/dev/null | awk '{print $1 * 1024}')"

# Populate all active keys without DNS so the second pass measures manifest
# reuse + compact-cache join/aggregation only.
records="$VM_STATE_DIR/block-cache/v2-compact/records.tsv"
record_now="$(date +%s)"
awk -F '|' -v OFS='|' -v now="$record_now" '
    {
        line=$1 OFS $2 OFS $3
        for (slot=1; slot<=8; slot++)
            line=line OFS now OFS "203.0.113.10" OFS "" OFS 0
        print line
    }
' \
    "$VM_STATE_DIR/block-cache/v2-compact/active.tsv" > "$records.next"
mv "$records.next" "$records"
printf '%s\n' synthetic > "$VM_STATE_DIR/block-cache/v2-compact/records-ip-generation"
# Prime the derived nft aggregate after injecting synthetic records; the timed
# pass below is the normal no-stale steady state.
vm_pbr_generate_block
warm_start="$(date +%s)"
vm_pbr_generate_block
warm_finish="$(date +%s)"
warm_lookups=0
[ ! -f "$VM_BENCH_TRACE" ] || warm_lookups="$(wc -l < "$VM_BENCH_TRACE" | tr -d ' ')"

# Force every record stale and use the production 25-second budget. The total
# wall clock includes planning, bounded DNS waves, merge and nft synthesis.
VM_BLOCK_CACHE_TTL=0
VM_BLOCK_REFRESH_BUDGET=25
: > "$VM_BENCH_TRACE"
if [ "${VM_BENCH_SKIP_HARD:-0}" = "1" ]; then
    hard_start=0
    hard_finish=0
    hard_lookups=0
else
    hard_start="$(date +%s)"
    vm_pbr_generate_block
    hard_finish="$(date +%s)"
    hard_lookups="$(wc -l < "$VM_BENCH_TRACE" | tr -d ' ')"
fi

printf 'planning_seconds=%s\n' "$((first_dns - start))"
printf 'wall_seconds=%s\n' "$((finish - start))"
printf 'pairs=%s\n' "$pair_count"
printf 'tasks=%s\n' "$task_count"
printf 'lookups=%s\n' "$lookup_count"
printf 'cache_files=%s\n' "$cache_files"
printf 'cache_bytes=%s\n' "$cache_bytes"
printf 'process_baseline=%s\n' "$baseline"
printf 'process_peak=%s\n' "$peak"
printf 'warm_seconds=%s\n' "$((warm_finish - warm_start))"
printf 'warm_lookups=%s\n' "$warm_lookups"
printf 'hard_default_seconds=%s\n' "$((hard_finish - hard_start))"
printf 'hard_default_lookups=%s\n' "$hard_lookups"
cat "$VM_BLOCK_PHASE_TRACE"

rm -rf "$VM_STATE_DIR"
