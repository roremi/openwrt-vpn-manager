#!/bin/sh
set -eu

line='PrivateKey = supersecret'
redacted="$(echo "$line" | sed -E 's#(PrivateKey[[:space:]]*=[[:space:]]*)[^[:space:]]+#\1***REDACTED***#g')"

echo "$redacted" | grep -q 'REDACTED'
! echo "$redacted" | grep -q 'supersecret'

echo "unit redaction: ok"
