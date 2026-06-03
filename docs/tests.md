# Test Strategy

## Unit Tests

- parser: WireGuard .conf parsing
- validator: endpoint, key, CIDR, MAC formats
- pbr: fwmark/table generation and conflict detection
- redaction: private key masking in logs

## Integration Tests

- profile lifecycle create/edit/delete/toggle
- health-check detect outage and recover
- watchdog reconnect sequence
- device bulk assignment and route effect
- rollback on invalid candidate

## Non-Functional

- apply latency under 200 assigned devices
- no total network outage during single-profile updates
- memory footprint on low-RAM targets

## Security Tests

- RPC authorization by role
- CSRF token enforcement
- forbidden inter-zone path blocked when isolation on
