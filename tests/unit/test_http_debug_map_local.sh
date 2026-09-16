#!/bin/sh
set -eu

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$TEST_DIR/../.." && pwd)"
. "$REPO_ROOT/tests/lib/testlib.sh"

tmp_dir="$(make_test_tmpdir)"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
mkdir -p "$tmp_dir/bin" "$tmp_dir/state" "$tmp_dir/log"

cat > "$tmp_dir/bin/uci" <<'EOF'
#!/bin/sh
cat <<'CONFIG'
vpn-manager.global=global
vpn-manager.vpn_test=profile
vpn-manager.vpn_test.enabled='1'
vpn-manager.vpn_test.address='10.202.0.3/24'
vpn-manager.vpn_test.dns='10.152.0.1'
vpn-manager.vpn_test.table_id='121'
vpn-manager.vpn_test.iface='wg_test'
vpn-manager.wifi_test=wifi_binding
vpn-manager.wifi_test.enabled='1'
vpn-manager.wifi_test.target='vpn_test'
vpn-manager.wifi_test.subnet_id='21'
vpn-manager.http_phone=http_debug_client
vpn-manager.http_phone.ip='10.77.21.150'
vpn-manager.http_phone.enabled='1'
vpn-manager.http_disabled=http_debug_client
vpn-manager.http_disabled.ip='10.77.21.151'
vpn-manager.http_disabled.enabled='0'
vpn-manager.url_login=blocked_url
vpn-manager.url_login.protocol='https'
vpn-manager.url_login.host='example.com'
vpn-manager.url_login.method='POST'
vpn-manager.url_login.path='/api/login'
vpn-manager.url_login.enabled='1'
vpn-manager.url_disabled=blocked_url
vpn-manager.url_disabled.protocol='https'
vpn-manager.url_disabled.host='disabled.example'
vpn-manager.url_disabled.method='GET'
vpn-manager.url_disabled.path='/*'
vpn-manager.url_disabled.enabled='0'
vpn-manager.block_forter=blocked_domain
vpn-manager.block_forter.domain='forter.com'
vpn-manager.block_forter.mode='wildcard'
vpn-manager.block_forter.enabled='1'
vpn-manager.block_disabled=blocked_domain
vpn-manager.block_disabled.domain='disabled.example'
vpn-manager.block_disabled.mode='exact'
vpn-manager.block_disabled.enabled='0'
CONFIG
EOF
chmod 0755 "$tmp_dir/bin/uci"

VM_HTTP_DEBUG_DIR="$tmp_dir/state"
VM_HTTP_DEBUG_CLIENTS="$tmp_dir/state/clients.manifest"
VM_HTTP_DEBUG_ROUTES="$tmp_dir/state/routes.manifest"
VM_HTTP_DEBUG_URL_RULES="$tmp_dir/state/url-rules.manifest"
VM_HTTP_DEBUG_BUMP_HOSTS="$tmp_dir/state/bump-hosts.manifest"
VM_HTTP_DEBUG_RESOLVERS="$tmp_dir/state/resolvers.manifest"
VM_HTTP_DEBUG_BLOCKED_DOMAINS="$tmp_dir/state/blocked-domains.manifest"
VM_HTTP_DEBUG_SQUID_CONFIG="$tmp_dir/state/squid.conf"
VM_HTTP_DEBUG_NFT_FILE="$tmp_dir/state/access.nft"
VM_HTTP_DEBUG_PID_FILE="$tmp_dir/state/proxy.pid"
VM_HTTP_DEBUG_SSL_DB="$tmp_dir/state/ssl-db"
VM_HTTP_DEBUG_LOG_DIR="$tmp_dir/log"
VM_HTTP_DEBUG_ACCESS_LOG="$tmp_dir/log/access.log"
VM_HTTP_DEBUG_CERT_DIR="$tmp_dir/certs"
PATH="$tmp_dir/bin:$PATH"
export VM_HTTP_DEBUG_DIR VM_HTTP_DEBUG_CLIENTS VM_HTTP_DEBUG_ROUTES
export VM_HTTP_DEBUG_URL_RULES VM_HTTP_DEBUG_BUMP_HOSTS VM_HTTP_DEBUG_RESOLVERS VM_HTTP_DEBUG_BLOCKED_DOMAINS VM_HTTP_DEBUG_SQUID_CONFIG VM_HTTP_DEBUG_NFT_FILE
export VM_HTTP_DEBUG_PID_FILE VM_HTTP_DEBUG_SSL_DB VM_HTTP_DEBUG_LOG_DIR
export VM_HTTP_DEBUG_ACCESS_LOG VM_HTTP_DEBUG_CERT_DIR PATH

sh "$REPO_ROOT/scripts/vpn-http-debug.sh" plan

assert_eq '10.77.21.150|10.202.0.3|121|wg_test' "$(cat "$VM_HTTP_DEBUG_CLIENTS")" "SSID client was not mapped to its VPN source"
assert_eq '10.202.0.3|121|wg_test' "$(cat "$VM_HTTP_DEBUG_ROUTES")" "VPN source route plan is wrong"
assert_eq '10.152.0.1' "$(cat "$VM_HTTP_DEBUG_RESOLVERS")" "VPN DNS resolver plan is wrong"
assert_eq 'forter.com|wildcard' "$(cat "$VM_HTTP_DEBUG_BLOCKED_DOMAINS")" "wildcard domain block plan is wrong"
grep -q 'disabled.example' "$VM_HTTP_DEBUG_BLOCKED_DOMAINS" && fail "disabled domain block was emitted"
grep -q '|POST$' "$VM_HTTP_DEBUG_URL_RULES" || fail "HTTP method constraint missing"
grep -q 'disabled.example' "$VM_HTTP_DEBUG_URL_RULES" && fail "disabled URL rule was emitted"
assert_eq 'example.com' "$(cat "$VM_HTTP_DEBUG_BUMP_HOSTS")" "HTTPS bump host plan is wrong"

sh "$REPO_ROOT/scripts/vpn-http-debug.sh" generate-squid
grep -q '^https_port 3129 intercept ssl-bump' "$VM_HTTP_DEBUG_SQUID_CONFIG" || fail "transparent HTTPS port missing"
grep -q '^dns_nameservers 10.152.0.1$' "$VM_HTTP_DEBUG_SQUID_CONFIG" || fail "Squid must use the selected VPN DNS"
grep -q '^acl vm_domain_1 dstdomain \.forter.com$' "$VM_HTTP_DEBUG_SQUID_CONFIG" || fail "Squid wildcard domain ACL missing"
grep -q '^http_access deny vm_domain_1$' "$VM_HTTP_DEBUG_SQUID_CONFIG" || fail "Squid domain deny missing"
grep -q '^tcp_outgoing_address 10.202.0.3 vm_client_1$' "$VM_HTTP_DEBUG_SQUID_CONFIG" || fail "Squid VPN source binding missing"
grep -q '^http_access deny vm_url_1 vm_method_1$' "$VM_HTTP_DEBUG_SQUID_CONFIG" || fail "exact URL/method deny missing"
grep -q '^acl vm_bump_hosts ssl::server_name example.com$' "$VM_HTTP_DEBUG_SQUID_CONFIG" || fail "selective TLS bump ACL missing"
grep -q '^ssl_bump bump vm_bump_hosts$' "$VM_HTTP_DEBUG_SQUID_CONFIG" || fail "selective TLS bump action missing"
grep -q '^ssl_bump splice all$' "$VM_HTTP_DEBUG_SQUID_CONFIG" || fail "non-target TLS splice fallback missing"
grep -q '^ssl_bump bump all$' "$VM_HTTP_DEBUG_SQUID_CONFIG" && fail "global TLS bump must not be enabled"
grep -q '^log_mime_hdrs on$' "$VM_HTTP_DEBUG_SQUID_CONFIG" || fail "full header logging missing"
grep -q '^forwarded_for delete$' "$VM_HTTP_DEBUG_SQUID_CONFIG" || fail "client IP forwarding was not disabled"
grep -q '^via off$' "$VM_HTTP_DEBUG_SQUID_CONFIG" || fail "proxy-identifying Via header was not disabled"

sh "$REPO_ROOT/scripts/vpn-http-debug.sh" generate-access
grep -q '10.77.21.150' "$VM_HTTP_DEBUG_NFT_FILE" || fail "enabled HTTP debug client was not selected"
grep -q '10.77.21.151' "$VM_HTTP_DEBUG_NFT_FILE" && fail "disabled HTTP debug client was selected"
grep -q 'tcp dport 80 redirect to :3128' "$VM_HTTP_DEBUG_NFT_FILE" || fail "HTTP redirect missing"
grep -q 'tcp dport 443 redirect to :3129' "$VM_HTTP_DEBUG_NFT_FILE" || fail "HTTPS redirect missing"
grep -q 'udp dport 443 reject' "$VM_HTTP_DEBUG_NFT_FILE" || fail "QUIC bypass guard missing"
grep -q 'ip saddr 10.202.0.3 oifname != "wg_test" drop' "$VM_HTTP_DEBUG_NFT_FILE" || fail "VPN fail-closed output guard missing"
grep -q 'conntrack -D -s "$ip" -p tcp' "$REPO_ROOT/scripts/vpn-http-debug.sh" || fail "selected TCP flow reset missing"
grep -q 'conntrack -D -s "$ip" -p udp' "$REPO_ROOT/scripts/vpn-http-debug.sh" || fail "selected UDP flow reset missing"
grep -q 'rule add to "$subnet" table main priority 9980' "$REPO_ROOT/scripts/vpn-http-debug.sh" || fail "dedicated WiFi return route missing"
grep -q 'rule del to "$subnet" table main priority 9980' "$REPO_ROOT/scripts/vpn-http-debug.sh" || fail "dedicated WiFi return-route cleanup missing"

echo "transparent HTTP debug plan: ok"
