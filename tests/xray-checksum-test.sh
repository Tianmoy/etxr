#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1091
source "$ROOT/etxr.sh"

expected="23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae"

cat >"$TMP/current.dgst" <<EOF
MD5= ee4e2ff74948a9b464624b1cabc44409
SHA1= b55b06e74e89083b9cedfdecf0d68b579cd2af72
SHA2-256= $expected
SHA2-512= e8bc40a0687cac184bbe4b5c1f047e69064ccedc489fb25e208889ae287bbf8736dff16b108d68fc00dc33edc8bb53502e47a9698a277f4f51b67b83d899e518
EOF
test "$(parse_xray_sha256_dgst "$TMP/current.dgst")" = "$expected"

printf 'SHA256 = %s\n' "$expected" >"$TMP/legacy.dgst"
test "$(parse_xray_sha256_dgst "$TMP/legacy.dgst")" = "$expected"

printf 'SHA-256=%s\n' "$expected" >"$TMP/dashed.dgst"
test "$(parse_xray_sha256_dgst "$TMP/dashed.dgst")" = "$expected"

printf 'SHA2-512=%0128d\n' 0 >"$TMP/missing.dgst"
test -z "$(parse_xray_sha256_dgst "$TMP/missing.dgst")"

echo "xray-checksum-test: PASS"
