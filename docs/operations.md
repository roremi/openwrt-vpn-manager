# Operations Runbook

## Daily checks

1. Verify active profiles and handshake age.
2. Check watchdog reconnect counters.
3. Verify policy assignments changed in last 24h.

## Health Signals

- Healthy: recent handshake <= 180s and ping success >= 80%
- Degraded: handshake stale but endpoint reachable
- Down: no handshake and probes fail

## Common Procedures

### Rotate endpoint for one VPN

1. Update profile endpoint.
2. Apply staged config.
3. Run profile test.
4. Confirm unaffected profiles still up.

### Move one device WAN -> VPN B

1. Open devices list.
2. Set target to profile VPN B.
3. Apply.
4. Validate route with traceroute from client.

### Emergency fail-open

1. Disable kill-switch for impacted profile.
2. Reassign critical devices to WAN.
3. Investigate VPN provider issue.

## Backup/Restore

- Backup:

/usr/libexec/vpn-manager/backup.sh /tmp/vpn-manager-backup.tgz

- Restore:

/usr/libexec/vpn-manager/restore.sh /tmp/vpn-manager-backup.tgz

## Audit Compliance

- Confirm no private key appears in:
  - /var/log/vpn-manager/audit.log
  - logread output
