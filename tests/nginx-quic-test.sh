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
if nginx_quic_file_has_active "$TMP/nginx/sites-enabled/site.conf"; then
  echo "successful apply left nginx H3/QUIC enabled" >&2
  exit 1
fi
grep -Fq 'listen 443 ssl;' "$TMP/nginx/sites-enabled/site.conf"
find "$ETXR_BACKUPS" -path '*/nginx-quic/manifest' -type f | grep -q .

printf 'nginx-quic-test: PASS\n'
