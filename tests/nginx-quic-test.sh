#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
if ! command -v jq >/dev/null 2>&1 && [[ -x "$ROOT/tools/jq" ]]; then
  PATH="$ROOT/tools:$PATH"
fi
cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/nginx/sites-enabled" "$TMP/backup"
cat >"$TMP/nginx/sites-enabled/site.conf" <<'EOF'
server {
    listen 443 ssl;
    listen 443 quic reuseport;
    listen [::]:443 quic reuseport;
    http2 on;
    http3 on;
    quic_retry on;
    quic_gso on;
    ssl_early_data on;
    add_header Alt-Svc 'quic=":443"; h3=":443"; h3-29=":443"';
}
EOF
cat >"$TMP/nginx/nginx.conf" <<'EOF'
events {}
http {
    include sites-enabled/*.conf;
}
EOF
cp "$TMP/nginx/sites-enabled/site.conf" "$TMP/original.conf"

export ETXR_NGINX_SCAN_ROOTS="$TMP/nginx/nginx.conf:$TMP/nginx/sites-enabled"
export ETXR_STATE="$TMP/runtime/state.json"
export ETXR_RUNTIME="$TMP/runtime"
export ETXR_GENERATED="$TMP/runtime/generated"
export ETXR_BACKUPS="$TMP/runtime/backups"
export ETXR_SUBSCRIPTIONS="$TMP/runtime/subscriptions"
export ETXR_CONTROL_DIR="$TMP/runtime/control"
export ETXR_CONTROL_HELPER="$TMP/runtime/control.py"
export ETXR_LIMITER_CONFIG="$TMP/runtime/live/limits.json"
export ETXR_USAGE_FILE="$TMP/runtime/usage.json"
export ETXR_DOMAIN_FILE="$TMP/runtime/domains.json"
export ETXR_DOMAIN_SOCKET="$TMP/run/etxr/domain-audit.sock"
export ETXR_SYSTEMD_UNIT_DIR="$TMP/runtime/systemd"
export ETXR_WAIT_IP_HELPER="$TMP/runtime/wait-ip"
export ETXR_DATAPLANE_BIN="$TMP/runtime/etxr-dataplane"
export XRAY_BIN="$TMP/tools/xray"
export SING_BOX_BIN="$TMP/tools/sing-box"
# shellcheck source=etxr.sh
source "$ROOT/etxr.sh"

manifest="$TMP/active.manifest"
nginx_quic_active_manifest "$manifest"
[[ -s "$manifest" ]]

active_count=0
while IFS= read -r -d '' file; do
  [[ "$file" == "$TMP/nginx/sites-enabled/site.conf" ]]
  active_count="$((active_count + 1))"
done <"$manifest"
[[ "$active_count" -eq 1 ]]

nginx_quic_disable_manifest "$manifest" "$TMP/backup"
[[ "$NGINX_QUIC_CHANGED" -eq 1 ]]
if nginx_quic_file_has_active "$TMP/nginx/sites-enabled/site.conf"; then
  echo "nginx H3/QUIC directives are still active" >&2
  exit 1
fi

grep -Fq 'listen 443 ssl;' "$TMP/nginx/sites-enabled/site.conf"
grep -Fq 'http2 on;' "$TMP/nginx/sites-enabled/site.conf"
grep -Fq 'ssl_early_data on;' "$TMP/nginx/sites-enabled/site.conf"
grep -Fq '# etxr-hy2-udp443: listen 443 quic reuseport;' \
  "$TMP/nginx/sites-enabled/site.conf"
grep -Fq '# etxr-hy2-udp443: listen [::]:443 quic reuseport;' \
  "$TMP/nginx/sites-enabled/site.conf"
grep -Fq 'http3 off; # etxr-hy2-udp443: was on' \
  "$TMP/nginx/sites-enabled/site.conf"
grep -Fq '# etxr-hy2-udp443: add_header Alt-Svc' \
  "$TMP/nginx/sites-enabled/site.conf"

nginx_quic_restore_backup "$TMP/backup"
cmp "$TMP/original.conf" "$TMP/nginx/sites-enabled/site.conf"

# nginx reload is asynchronous: old workers may hold UDP 443 briefly.
udp_owner_checks=0
port_is_nginx_owned() {
  if [[ "$1" == "udp" && "$2" == "443" ]]; then
    udp_owner_checks="$((udp_owner_checks + 1))"
    (( udp_owner_checks < 4 ))
    return
  fi
  return 1
}
sleep() { :; }
wait_for_nginx_udp_release 443 5
[[ "$udp_owner_checks" -eq 4 ]]

port_is_nginx_owned() {
  [[ "$1" == "udp" && "$2" == "443" ]]
}
if wait_for_nginx_udp_release 443 1; then
  echo "persistent nginx UDP ownership was accepted" >&2
  exit 1
fi

# Parse files from nginx -T so custom Baota include paths are also scanned.
mkdir -p "$TMP/effective"
cat >"$TMP/effective/custom-vhost.any-name" <<'EOF'
server {
    listen 443 quic;
}
EOF
cat >"$TMP/effective/nginx" <<EOF
#!/usr/bin/env bash
printf '%s\n' '# configuration file $TMP/effective/custom-vhost.any-name:'
EOF
chmod 755 "$TMP/effective/nginx"
unset ETXR_NGINX_SCAN_ROOTS
export ETXR_NGINX_EFFECTIVE_BIN="$TMP/effective/nginx"
effective_file="$(nginx_effective_config_files)"
[[ "$effective_file" == "$TMP/effective/custom-vhost.any-name" ]]
unset ETXR_NGINX_EFFECTIVE_BIN
export ETXR_NGINX_SCAN_ROOTS="$TMP/nginx/nginx.conf:$TMP/nginx/sites-enabled"

# A Baota site added after the first scan must be discovered by the next
# repair/apply run instead of relying on a previous manifest.
cat >"$TMP/nginx/sites-enabled/new-site.conf" <<'EOF'
server {
    listen 443 ssl;
    listen 443 quic;
    http3 on;
    add_header Alt-Svc 'h3=":443"';
}
EOF
new_manifest="$TMP/new-site.manifest"
nginx_quic_active_manifest "$new_manifest"
grep -Fzxq "$TMP/nginx/sites-enabled/new-site.conf" "$new_manifest"
nginx_quic_disable_manifest "$new_manifest" "$TMP/new-site-backup"
if nginx_quic_file_has_active "$TMP/nginx/sites-enabled/new-site.conf"; then
  echo "newly added nginx site still has H3/QUIC enabled" >&2
  exit 1
fi
nginx_quic_restore_backup "$TMP/new-site-backup"
grep -Fq 'listen 443 quic;' "$TMP/nginx/sites-enabled/new-site.conf"

# TCP 443 migration keeps QUIC lines untouched and is independently reversible.
tcp_manifest="$TMP/tcp443.manifest"
nginx_tcp443_active_manifest "$tcp_manifest"
[[ -s "$tcp_manifest" ]]
nginx_tcp443_rebind_manifest "$tcp_manifest" "$TMP/tcp443-backup" 8443
[[ "$NGINX_TCP443_CHANGED" -eq 1 ]]
grep -Fq 'listen 127.0.0.1:8443 ssl; # etxr-tcp443: was public 443' \
  "$TMP/nginx/sites-enabled/site.conf"
grep -Fq 'listen 443 quic reuseport;' "$TMP/nginx/sites-enabled/site.conf"
nginx_tcp443_restore_backup "$TMP/tcp443-backup"
cmp "$TMP/original.conf" "$TMP/nginx/sites-enabled/site.conf"

# A post-change nginx validation failure must restore every H3/QUIC line.
mkdir -p "$TMP/tools" "$ETXR_SYSTEMD_UNIT_DIR"
cat >"$XRAY_BIN" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$SING_BOX_BIN" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$TMP/tools/nginx" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "-t" ]] &&
   grep -Fq 'etxr-hy2-udp443' "$TMP/nginx/sites-enabled/site.conf"; then
  exit 1
fi
exit 0
EOF
cat >"$TMP/tools/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$TMP/tools/chown" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$XRAY_BIN" "$SING_BOX_BIN" "$TMP/tools/nginx" \
  "$TMP/tools/systemctl" "$TMP/tools/chown"

PATH="$TMP/tools:$PATH"
export PATH
need_root() { return 0; }
install_data_helper() { return 0; }
ensure_control_runtime() { return 0; }
write_systemd_units() { return 0; }
configure_ufw_from_state() { return 0; }
nginx_bin() { printf '%s' "$TMP/tools/nginx"; }
nginx_process_running() { return 0; }
port_is_listening() { return 1; }
port_is_nginx_owned() { return 1; }
port_is_sing_box_owned() { return 1; }

cmd_init --name rollback --role gateway --domain rollback.example.com \
  --address rollback.example.com --nginx-mode disabled \
  --cert "$TMP/cert.pem" --key "$TMP/key.pem" \
  --xray-config "$TMP/runtime/live/xray.json" \
  --sing-box-config "$TMP/runtime/live/sing-box.json"
state_update '
  .control.enabled = false |
  .domain_audit.enabled = true |
  .hysteria2.enabled = true |
  .hysteria2.port = 443 |
  .hysteria2.shared_udp443 = true |
  .hysteria2.obfs_password = "test-password" |
  .hysteria2.masquerade = "https://rollback.example.com"
'

if (cmd_apply >/dev/null 2>&1); then
  echo "apply unexpectedly accepted the injected nginx validation failure" >&2
  exit 1
fi
cmp "$TMP/original.conf" "$TMP/nginx/sites-enabled/site.conf"

# The same state succeeds once nginx validation and the HY2 listener pass.
cat >"$TMP/tools/nginx" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$TMP/tools/nginx"
verify_hy2_udp_listener() { return 0; }
cmd_apply >/dev/null
[[ "$(stat -c '%a' "$(dirname "$SUBSCRIPTION_DIR")")" == "751" ]]
[[ "$(stat -c '%a' "$SUBSCRIPTION_DIR")" == "750" ]]
chmod 700 "$(dirname "$SUBSCRIPTION_DIR")"
cmd_subscriptions_refresh >/dev/null
[[ "$(stat -c '%a' "$(dirname "$SUBSCRIPTION_DIR")")" == "751" ]]
if nginx_quic_file_has_active "$TMP/nginx/sites-enabled/site.conf"; then
  echo "successful apply left nginx H3/QUIC enabled" >&2
  exit 1
fi
grep -Fq 'listen 443 ssl;' "$TMP/nginx/sites-enabled/site.conf"
find "$ETXR_BACKUPS" -path '*/nginx-quic/manifest' -type f | grep -q .

# Shared Reality + HTTPS + HY2 changes TCP 443 and QUIC together. A validation
# failure after both rewrites must restore the complete Baota vhost.
nginx_quic_restore_backup "$TMP/backup"
cmp "$TMP/original.conf" "$TMP/nginx/sites-enabled/site.conf"
mkdir -p "$TMP/nginx/tcp" "$TMP/runtime/baota"
FORCE=1
cmd_init --name shared-worker --role exit --domain worker.example.com \
  --address worker.example.com --nginx-mode snippet \
  --snippet "$TMP/runtime/baota/etxr.conf" \
  --nginx-shared-tcp443 true --nginx-auto-rebind-https true \
  --nginx-https-listen-port 8443 \
  --nginx-stream-path "$TMP/nginx/tcp/etxr.conf" \
  --cert "$TMP/cert.pem" --key "$TMP/key.pem" \
  --xray-config "$TMP/runtime/live/xray.json" \
  --sing-box-config "$TMP/runtime/live/sing-box.json"
FORCE=0
cmd_user_add --name admin \
  --uuid 11111111-1111-4111-8111-111111111111 \
  --password TEST-HY2-PASSWORD >/dev/null
state_update '
  .xray.routes = [{
    name: "shared-xhttp",
    listen: "127.0.0.1",
    port: 18000,
    public_port: 443,
    path: "/shared-xhttp",
    target: "direct",
    profile: "plain",
    host: "",
    decryption: "none",
    client_encryption: "none",
    flow: "",
    direct: true,
    security: "none",
    certificate: "",
    certificate_key: "",
    allow_insecure: true
  }] |
  .xray.reality_inbounds = [{
    name: "direct",
    listen: "127.0.0.1",
    port: 443,
    listen_port: 18443,
    path: "/shared-reality",
    target: "aod.itunes.apple.com:443",
    server_names: ["aod.itunes.apple.com"],
    private_key: "TEST-PRIVATE",
    public_key: "TEST-PUBLIC",
    short_ids: ["0123456789abcdef"]
  }] |
  .hysteria2.enabled = true |
  .hysteria2.port = 443 |
  .hysteria2.shared_udp443 = true |
  .hysteria2.obfs_password = "test-password" |
  .hysteria2.masquerade = "https://worker.example.com"
'
nginx_supports_stream_preread() { return 0; }
cat >"$TMP/tools/nginx" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "-t" ]] &&
   grep -Fq 'etxr-tcp443' "$TMP/nginx/sites-enabled/site.conf" &&
   grep -Fq 'etxr-hy2-udp443' "$TMP/nginx/sites-enabled/site.conf"; then
  exit 1
fi
exit 0
EOF
chmod 755 "$TMP/tools/nginx"
if (cmd_apply >/dev/null 2>&1); then
  echo "shared 443 apply unexpectedly accepted nginx validation failure" >&2
  exit 1
fi
cmp "$TMP/original.conf" "$TMP/nginx/sites-enabled/site.conf"
[[ ! -e "$TMP/nginx/tcp/etxr.conf" ]]
[[ ! -e "$TMP/runtime/baota/etxr.conf" ]]

cat >"$TMP/tools/nginx" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$TMP/tools/nginx"
cmd_apply >/dev/null
grep -Fq 'listen 127.0.0.1:8443 ssl;' \
  "$TMP/nginx/sites-enabled/site.conf"
if nginx_quic_file_has_active "$TMP/nginx/sites-enabled/site.conf"; then
  echo "shared 443 apply left nginx H3/QUIC enabled" >&2
  exit 1
fi
grep -Fq 'listen 443;' "$TMP/nginx/tcp/etxr.conf"
grep -Fq 'aod.itunes.apple.com etxr_reality_0;' \
  "$TMP/nginx/tcp/etxr.conf"
grep -Fq 'proxy_pass http://127.0.0.1:18000;' \
  "$TMP/runtime/baota/etxr.conf"
find "$ETXR_BACKUPS" -path '*/nginx-tcp443/manifest' -type f | grep -q .

# Standard nginx must also remove every newly written file when validation
# fails after adding the dynamic stream loader.
mkdir -p "$TMP/standard/conf.d" "$TMP/standard/modules-enabled" \
  "$TMP/standard/stream-conf.d" "$TMP/standard/live"
cat >"$TMP/standard/nginx.conf" <<'EOF'
include /etc/nginx/modules-enabled/*.conf;
events {}
http {}
EOF
export ETXR_NGINX_SCAN_ROOTS="$TMP/standard/nginx.conf:$TMP/standard/conf.d"
FORCE=1
cmd_init --name standard-worker --role exit --domain standard.example.com \
  --address standard.example.com --nginx-mode standalone \
  --nginx-shared-tcp443 true --nginx-https-listen-port 8443 \
  --nginx-stream-path "$TMP/standard/stream-conf.d/etxr.conf" \
  --nginx-stream-loader-path "$TMP/standard/modules-enabled/99-etxr-stream.conf" \
  --cert "$TMP/cert.pem" --key "$TMP/key.pem" \
  --xray-config "$TMP/runtime/live/xray.json" \
  --sing-box-config "$TMP/runtime/live/sing-box.json"
FORCE=0
state_update '
  .nginx.standalone_path = $site |
  .nginx.paths_path = $paths |
  .nginx.web_root = $root |
  .xray.reality_inbounds = [{
    name: "direct",
    listen: "127.0.0.1",
    port: 443,
    listen_port: 18443,
    path: "/standard-reality",
    target: "aod.itunes.apple.com:443",
    server_names: ["aod.itunes.apple.com"],
    private_key: "TEST-PRIVATE",
    public_key: "TEST-PUBLIC",
    short_ids: ["0123456789abcdef"]
  }]
' --arg site "$TMP/standard/conf.d/etxr.conf" \
  --arg paths "$TMP/standard/live/nginx-paths.conf" \
  --arg root "$TMP/standard/www"
cmd_user_add --name admin \
  --uuid 11111111-1111-4111-8111-111111111111 \
  --password TEST-HY2-PASSWORD >/dev/null
check_baota_shared_nginx_layout() { return 0; }
cat >"$TMP/tools/nginx" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "-t" &&
      -e "$TMP/standard/modules-enabled/99-etxr-stream.conf" ]]; then
  exit 1
fi
exit 0
EOF
chmod 755 "$TMP/tools/nginx"
if (cmd_apply >/dev/null 2>&1); then
  echo "standard nginx apply unexpectedly accepted validation failure" >&2
  exit 1
fi
[[ ! -e "$TMP/standard/conf.d/etxr.conf" ]]
[[ ! -e "$TMP/standard/live/nginx-paths.conf" ]]
[[ ! -e "$TMP/standard/stream-conf.d/etxr.conf" ]]
[[ ! -e "$TMP/standard/modules-enabled/99-etxr-stream.conf" ]]

cat >"$TMP/tools/nginx" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$TMP/tools/nginx"
cmd_apply >/dev/null
[[ -f "$TMP/standard/conf.d/etxr.conf" ]]
[[ -f "$TMP/standard/live/nginx-paths.conf" ]]
[[ -f "$TMP/standard/stream-conf.d/etxr.conf" ]]
grep -Fq 'stream {' \
  "$TMP/standard/modules-enabled/99-etxr-stream.conf"

printf 'nginx-quic-test: PASS\n'
