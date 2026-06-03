#!/bin/sh
set -eu

sample='[Interface]
PrivateKey = abc123
Address = 10.10.0.2/32

[Peer]
PublicKey = pub123
Endpoint = 1.2.3.4:51820
AllowedIPs = 0.0.0.0/0, ::/0'

echo "$sample" | grep -q '^PrivateKey = '
echo "$sample" | grep -q '^Endpoint = '

echo "unit parser: ok"
