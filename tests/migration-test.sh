#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

if ! command -v jq >/dev/null 2>&1 && [[ -x "$ROOT/tools/jq" ]]; then
  PATH="$ROOT/tools:$PATH"
fi

export ETXR_STATE="$TMP/source/state.json"
export ETXR_RUNTIME="$TMP/source"
export ETXR_GENERATED="$TMP/source/generated"
export ETXR_BACKUPS="$TMP/source/backups"
export ETXR_SUBSCRIPTIONS="$TMP/source/subscriptions"
export ETXR_USAGE_FILE="$TMP/source/usage.json"
export ETXR_DOMAIN_FILE="$TMP/source/domains.json"
export ETXR_PAIR_KEY_DIR="$TMP/source/keys"
export ETXR_PAIR_PRIVATE_KEY="$TMP/source/keys/pair-signing.key"
export ETXR_PAIR_PUBLIC_KEY="$TMP/source/keys/pair-signing.pub"
# shellcheck source=etxr.sh
source "$ROOT/etxr.sh"

mkdir -p "$TMP/source" "$TMP/certs"
printf 'OLD CERTIFICATE CONTENT MUST NOT MIGRATE\n' >"$TMP/certs/fullchain.pem"
printf 'OLD PRIVATE KEY CONTENT MUST NOT MIGRATE\n' >"$TMP/certs/privkey.pem"

cmd_init --name hk --role gateway --domain old.example.com \
  --address old.example.com --nginx-mode snippet \
  --snippet /www/server/panel/vhost/nginx/extension/old.example.com/etxr.conf \
  --cert "$TMP/certs/fullchain.pem" --key "$TMP/certs/privkey.pem"
state_update '
  .nginx.shared_tcp443 = true |
  .nginx.auto_rebind_https = true |
  .nginx.stream_path = "/www/server/panel/vhost/nginx/tcp/etxr.conf" |
  .xray.routes = [{
    name: "direct-tls",
    listen: "0.0.0.0",
    port: 18444,
    public_port: 18444,
    path: "/direct-tls",
    target: "direct",
    profile: "plain",
    host: "",
    decryption: "none",
    client_encryption: "none",
    flow: "",
    direct: true,
    security: "tls",
    certificate: $cert,
    certificate_key: $key,
    allow_insecure: false
  }] |
  .xray.reality_inbounds = [{
    name: "reality",
    listen: "127.0.0.1",
    port: 443,
    listen_port: 18443,
    path: "/reality",
    target: "aod.itunes.apple.com:443",
    server_names: ["aod.itunes.apple.com"],
    private_key: "TEST_PRIVATE_KEY_1234567890",
    public_key: "TEST_PUBLIC_KEY_1234567890",
    short_ids: ["0123456789abcdef"]
  }]
' --arg cert "$TMP/certs/fullchain.pem" --arg key "$TMP/certs/privkey.pem"
printf '{"users":{"alice":{"uplink":123,"downlink":456}}}\n' >"$USAGE_FILE"
printf '{"users":{"alice":{"domains":{}}}}\n' >"$DOMAIN_FILE"
ensure_pair_signing_key

printf 'correct horse battery staple\n' >"$TMP/password"
package="$TMP/etxr-migration.etxrm"
cmd_migration_export --out "$package" --password-file "$TMP/password" >/dev/null
[[ -s "$package" ]]
[[ "$(stat -c '%a' "$package")" == "600" ]]
if grep -aFq 'OLD PRIVATE KEY CONTENT MUST NOT MIGRATE' "$package"; then
  echo "certificate private key leaked into migration package" >&2
  exit 1
fi

mapfile -t outer_members < <(tar -tf "$package")
[[ "${outer_members[*]}" == "manifest.json payload.enc payload.hmac" ]]

mkdir -p "$TMP/unpacked"
migration_unpack_package "$package" 'correct horse battery staple' "$TMP/unpacked"
cmp "$STATE_FILE" "$TMP/unpacked/state.json"
cmp "$USAGE_FILE" "$TMP/unpacked/usage.json"
cmp "$DOMAIN_FILE" "$TMP/unpacked/domains.json"
cmp "$PAIR_PRIVATE_KEY" "$TMP/unpacked/keys/pair-signing.key"
cmp "$PAIR_PUBLIC_KEY" "$TMP/unpacked/keys/pair-signing.pub"
[[ ! -e "$TMP/unpacked/certs" ]]

if (migration_unpack_package "$package" 'wrong password' "$TMP/wrong") \
  >/dev/null 2>&1; then
  echo "migration package accepted a wrong password" >&2
  exit 1
fi

mkdir -p "$TMP/tampered"
tar -xf "$package" -C "$TMP/tampered"
printf 'X' | dd of="$TMP/tampered/payload.enc" bs=1 seek=64 conv=notrunc \
  status=none
tar -C "$TMP/tampered" -cf "$TMP/tampered.etxrm" \
  manifest.json payload.enc payload.hmac
if (migration_unpack_package "$TMP/tampered.etxrm" \
  'correct horse battery staple' "$TMP/tampered-out") >/dev/null 2>&1; then
  echo "migration package accepted modified ciphertext" >&2
  exit 1
fi

mkdir -p "$TMP/new-certs"
printf 'new cert\n' >"$TMP/new-certs/fullchain.pem"
printf 'new key\n' >"$TMP/new-certs/privkey.pem"
migration_prepare_state "$TMP/unpacked/state.json" "$TMP/prepared.json" \
  new.example.com new.example.com snippet \
  "$TMP/new-certs/fullchain.pem" "$TMP/new-certs/privkey.pem"
if ! jq -e '
  . as $root |
  .node.domain == "new.example.com" and
  .node.address == "new.example.com" and
  .nginx.mode == "snippet" and
  (.nginx.snippet_path |
    endswith("/www/server/panel/vhost/nginx/extension/new.example.com/etxr.conf")) and
  (.nginx.stream_path |
    endswith("/www/server/panel/vhost/nginx/tcp/etxr.conf")) and
  .nginx.stream_loader_path == "" and
  (.nginx.certificate | endswith("/new-certs/fullchain.pem")) and
  (.nginx.certificate_key | endswith("/new-certs/privkey.pem")) and
  .hysteria2.certificate == .nginx.certificate and
  .hysteria2.certificate_key == .nginx.certificate_key and
  all(.xray.routes[] | select(.security == "tls");
    .certificate == $root.nginx.certificate and
    .certificate_key == $root.nginx.certificate_key)
' "$TMP/prepared.json" >/dev/null; then
  jq '{node, nginx, hysteria2, routes: .xray.routes}' "$TMP/prepared.json" >&2
  exit 1
fi
if grep -Fq "$TMP/certs/privkey.pem" "$TMP/prepared.json"; then
  echo "prepared state retained the old certificate key path" >&2
  exit 1
fi

# Exercise the import transaction without installing services on the test host.
STATE_FILE="$TMP/target/state.json"
RUNTIME_DIR="$TMP/target/runtime"
GENERATED_DIR="$RUNTIME_DIR/generated"
BACKUP_DIR="$RUNTIME_DIR/backups"
USAGE_FILE="$TMP/target/usage.json"
DOMAIN_FILE="$TMP/target/domains.json"
PAIR_KEY_DIR="$TMP/target/keys"
PAIR_PRIVATE_KEY="$PAIR_KEY_DIR/pair-signing.key"
PAIR_PUBLIC_KEY="$PAIR_KEY_DIR/pair-signing.pub"
STATE_LOCK_HELD=0
STATE_LOCK_DEPTH=0
cmd_install() { return 0; }
tls_certificate_is_usable() { return 0; }
tls_certificate_matches_name() { return 0; }
cmd_apply() { return 0; }

(migration_import_impl "$package" 'correct horse battery staple' \
  imported.example.com imported.example.com standalone \
  /new/fullchain.pem /new/privkey.pem) >/dev/null
jq -e '
  .node.domain == "imported.example.com" and
  .node.address == "imported.example.com" and
  .nginx.mode == "standalone" and
  (.nginx.certificate | endswith("/new/fullchain.pem")) and
  (.nginx.certificate_key | endswith("/new/privkey.pem"))
' "$STATE_FILE" >/dev/null
cmp "$USAGE_FILE" "$TMP/unpacked/usage.json"
cmp "$DOMAIN_FILE" "$TMP/unpacked/domains.json"
cmp "$PAIR_PRIVATE_KEY" "$TMP/unpacked/keys/pair-signing.key"
cmp "$PAIR_PUBLIC_KEY" "$TMP/unpacked/keys/pair-signing.pub"

# A failed apply must restore the target state and data from before the import.
jq '.node.name = "before-failed-import"' "$STATE_FILE" >"$TMP/before.json"
install -m 600 "$TMP/before.json" "$STATE_FILE"
printf '{"before":true}\n' >"$USAGE_FILE"
cp "$STATE_FILE" "$TMP/expected-state.json"
cp "$USAGE_FILE" "$TMP/expected-usage.json"
cmd_apply() { return 1; }
if (migration_import_impl "$package" 'correct horse battery staple' \
    imported.example.com imported.example.com standalone \
    /new/fullchain.pem /new/privkey.pem) >/dev/null 2>&1; then
  echo "migration import accepted a failed apply" >&2
  exit 1
fi
cmp "$STATE_FILE" "$TMP/expected-state.json"
cmp "$USAGE_FILE" "$TMP/expected-usage.json"

printf 'migration-test: PASS\n'
