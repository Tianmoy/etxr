#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=etxr.sh
source "$ROOT/etxr.sh"

failures=0
warnings=0
health_result 0 "failure-counter" >/dev/null
health_result 2 "warning-counter" >/dev/null
[[ "$failures" == 1 ]]
[[ "$warnings" == 1 ]]

ss() {
  printf '%s\n' \
    'LISTEN 0 4096 127.0.0.1:18000 0.0.0.0:* users:(("xray",pid=123,fd=7))' \
    'UNCONN 0 0 64.83.27.18:443 0.0.0.0:* users:(("sing-box",pid=124,fd=11))'
}
listener_address_owned tcp 127.0.0.1 18000 xray
listener_address_owned udp 64.83.27.18 443 sing-box
if listener_address_owned udp 64.83.27.19 443 sing-box; then
  echo 'listener address matching is too loose' >&2
  exit 1
fi
unset -f ss

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -nodes -days 30 -subj '/CN=health.example' \
  -addext 'subjectAltName=DNS:health.example' \
  -keyout "$TMP/good.key" -out "$TMP/good.crt" >/dev/null 2>&1
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -nodes -days 30 -subj '/CN=other.example' \
  -addext 'subjectAltName=DNS:other.example' \
  -keyout "$TMP/other.key" -out "$TMP/other.crt" >/dev/null 2>&1

health_certificate "$TMP/good.crt" "$TMP/good.key" health.example >"$TMP/cert.out"
grep -q 'TLS 证书' "$TMP/cert.out"
grep -Eq '匹配|剩余' "$TMP/cert.out"
if health_certificate "$TMP/good.crt" "$TMP/other.key" health.example >"$TMP/bad.out" 2>&1; then
  :
else
  grep -q '不匹配' "$TMP/bad.out"
fi

printf 'health-check-test: PASS\n'
