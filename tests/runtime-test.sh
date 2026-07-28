#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="${TMPDIR:-/tmp}/etxr-runtime-test"
TOOLS="${TMP}/tools"
JQ="${JQ:-jq}"
XRAY="${XRAY:-${TOOLS}/xray}"
SING_BOX="${SING_BOX:-${TOOLS}/sing-box}"

TEST_PIDS=()
stop_test_processes() {
  local pid
  if ((${#TEST_PIDS[@]} == 0)); then
    return 0
  fi
  for pid in "${TEST_PIDS[@]}"; do
    kill "$pid" >/dev/null 2>&1 || true
  done
  sleep 1
  for pid in "${TEST_PIDS[@]}"; do
    if kill -0 "$pid" >/dev/null 2>&1; then
      kill -KILL "$pid" >/dev/null 2>&1 || true
    fi
  done
  wait "${TEST_PIDS[@]}" >/dev/null 2>&1 || true
  TEST_PIDS=()
}

cleanup() {
  stop_test_processes
  rm -rf "$TMP"
}
trap cleanup EXIT
mkdir -p "$TOOLS" "$(dirname "$XRAY")" "$(dirname "$SING_BOX")"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
need curl
need unzip
need tar
need openssl
need "$JQ"
JQ="$(readlink -f "$(command -v "$JQ")")"

curl_download() {
  curl --fail --silent --show-error --location \
    --connect-timeout 15 --max-time 120 \
    --retry 3 --retry-delay 2 --retry-max-time 180 "$@"
}

github_api() {
  local headers=()
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    headers=(
      --header "Authorization: Bearer ${GITHUB_TOKEN}"
      --header "X-GitHub-Api-Version: 2022-11-28"
    )
  fi
  curl_download "${headers[@]}" "$@"
}

free_tcp_port() {
  python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

wait_tcp() {
  local port="$1"
  for _ in $(seq 1 100); do
    if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
      exec 3>&-
      exec 3<&-
      return 0
    fi
    sleep 0.05
  done
  return 1
}

if [[ ! -x "$XRAY" ]]; then
  api="$(github_api https://api.github.com/repos/XTLS/Xray-core/releases/latest)"
  url="$("$JQ" -r '.assets[] | select(.name=="Xray-linux-64.zip") | .browser_download_url' <<<"$api")"
  curl_download "$url" -o "$TOOLS/xray.zip"
  unzip -p "$TOOLS/xray.zip" xray >"$XRAY"
  chmod 755 "$XRAY"
fi

if [[ ! -x "$SING_BOX" ]]; then
  api="$(github_api https://api.github.com/repos/SagerNet/sing-box/releases/latest)"
  tag="$("$JQ" -r '.tag_name' <<<"$api")"
  ver="${tag#v}"
  asset="sing-box-${ver}-linux-amd64.tar.gz"
  url="$("$JQ" -r --arg n "$asset" '.assets[] | select(.name==$n) | .browser_download_url' <<<"$api")"
  curl_download "$url" -o "$TOOLS/$asset"
  tar -xzf "$TOOLS/$asset" -C "$TOOLS"
  cp "$TOOLS/sing-box-${ver}-linux-amd64/sing-box" "$SING_BOX"
  chmod 755 "$SING_BOX"
fi

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj /CN=hk.example.com \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" >/dev/null 2>&1

reality_keys="$("$XRAY" x25519)"
reality_private="$(awk -F': ' '/^PrivateKey:/ {print $2}' <<<"$reality_keys")"
reality_public="$(awk -F': ' '/^Password/ {print $2}' <<<"$reality_keys")"
vlessenc_keys="$("$XRAY" vlessenc)"
# Select the final pair: ML-KEM-768 authentication.
server_decryption="$(awk -F'"' '/"decryption"/ {v=$4} END {print v}' <<<"$vlessenc_keys")"
client_encryption="$(awk -F'"' '/"encryption"/ {v=$4} END {print v}' <<<"$vlessenc_keys")"

PATH="$(dirname "$JQ"):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH
export ETXR_STATE="$TMP/state.json"
export ETXR_RUNTIME="$TMP"
export ETXR_GENERATED="$TMP/generated"
export ETXR_SUBSCRIPTIONS="$TMP/subscriptions"
export XRAY_BIN="$XRAY"
export SING_BOX_BIN="$SING_BOX"
DATAPLANE_BIN="$TMP/etxr-dataplane"
if [[ -n "${ETXR_TEST_DATAPLANE_BIN:-}" ]]; then
  install -m 755 "$ETXR_TEST_DATAPLANE_BIN" "$DATAPLANE_BIN"
else
  need go
  (cd "$ROOT" && go build -buildvcs=false \
    -ldflags '-s -w -X main.version=0.11.0' \
    -o "$DATAPLANE_BIN" ./cmd/etxr-dataplane)
fi
[[ "$("$DATAPLANE_BIN" version)" == "0.11.0" ]]
export ETXR_DATAPLANE_SOURCE="$DATAPLANE_BIN"
export ETXR_DATAPLANE_BIN="$DATAPLANE_BIN"

EDGE="$ROOT/etxr.sh"
"$EDGE" init --name hk --role gateway --domain hk.example.com \
  --address hk.example.com --nginx-mode standalone \
  --cert "$TMP/cert.pem" --key "$TMP/key.pem"
"$EDGE" user add --name alice \
  --uuid 11111111-1111-4111-8111-111111111111 --password HY2PASS >/dev/null
"$EDGE" user limit alice --up-mbps 5 --down-mbps 20
"$EDGE" exit add --name tw --address tw.example.com --port 443 \
  --transport tls --server-name tw.example.com --host tw.example.com \
  --path /relay-tw --uuid 22222222-2222-4222-8222-222222222222
"$EDGE" route add --name hk --path /entry-hk --port 18001 --target direct
"$EDGE" route add --name tw --path /entry-tw --port 18002 --target tw
"$EDGE" route add --name pq --path /entry-pq --port 18003 --target direct \
  --profile vlessenc-vision \
  --decryption "$server_decryption" \
  --client-encryption "$client_encryption"
"$EDGE" reality add --name backup --port 18443 --path /reality-backup \
  --target www.microsoft.com:443 --server-names www.microsoft.com \
  --private-key "$reality_private" --public-key "$reality_public" \
  --short-ids 0123456789abcdef
"$EDGE" hy2 enable --port 8443 --up-mbps 30 --down-mbps 200 \
  --obfs salamander --obfs-password OBFSPASS >/dev/null

"$EDGE" render

"$XRAY" run -test -config "$TMP/generated/xray.json"
"$SING_BOX" check -c "$TMP/generated/sing-box.json"
"$JQ" -e '.users[] | select(
  .name == "alice" and .subscription_prefix == "522b276a"
)' "$TMP/state.json" >/dev/null
grep -q 'location = /522b276a/' "$TMP/generated/nginx-paths.conf"
if grep -q 'location = /sub/' "$TMP/generated/nginx-paths.conf"; then
  echo "fixed /sub/ nginx location exists" >&2
  exit 1
fi

# Render the Baota shared TCP 443 layout. The test only renders configuration;
# it does not touch a real nginx installation.
export ETXR_STATE="$TMP/shared-state.json"
export ETXR_GENERATED="$TMP/shared-generated"
"$EDGE" init --name hk --role gateway --domain hk.example.com \
  --address hk.example.com --nginx-mode snippet \
  --snippet /www/server/panel/vhost/nginx/extension/hk.example.com/etxr.conf \
  --cert "$TMP/cert.pem" --key "$TMP/key.pem" \
  --nginx-shared-tcp443 true --nginx-https-listen-port 8443
"$EDGE" user add --name alice \
  --uuid 11111111-1111-4111-8111-111111111111 --password HY2PASS >/dev/null
"$EDGE" route add --name hk --path /entry-hk --port 18001 --target direct
"$EDGE" reality add --name reality --port 443 --listen-port 18443 \
  --listen-address 127.0.0.1 --path /reality \
  --target aod.itunes.apple.com:443 --server-names aod.itunes.apple.com \
  --private-key "$reality_private" --public-key "$reality_public" \
  --short-ids 0123456789abcdef
"$EDGE" render
"$JQ" -e '.nginx.shared_tcp443 == true' "$TMP/shared-state.json" >/dev/null
grep -q 'listen 443;' "$TMP/shared-generated/nginx-stream.conf"
grep -q 'aod.itunes.apple.com etxr_reality_0;' \
  "$TMP/shared-generated/nginx-stream.conf"
grep -q 'server 127.0.0.1:8443;' "$TMP/shared-generated/nginx-stream.conf"
grep -q '"port": 18443' "$TMP/shared-generated/xray.json"
export ETXR_STATE="$TMP/state.json"
export ETXR_GENERATED="$TMP/generated"

# A jq failure must stop rendering and preserve the previous generated file.
cp "$TMP/generated/xray.json" "$TMP/xray-before-render-failure.json"
mkdir -p "$TMP/failbin"
cat >"$TMP/failbin/jq" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "-n" ]]; then
  exit 42
fi
exec "$JQ" "\$@"
EOF
chmod 755 "$TMP/failbin/jq"
if PATH="$TMP/failbin:$PATH" "$EDGE" render >/dev/null 2>&1; then
  echo "render unexpectedly succeeded with a failing jq" >&2
  exit 1
fi
cmp "$TMP/generated/xray.json" "$TMP/xray-before-render-failure.json"
rm -rf "$TMP/failbin"

# Inject an Xray restart failure and verify live files, subscriptions, and
# systemd units are restored to their pre-apply state.
FAULT="$TMP/apply-rollback"
FAULT_BIN="$FAULT/bin"
FAULT_UNITS="$FAULT/systemd"
FAULT_LIVE="$FAULT/live"
FAULT_SUBS="$FAULT/subscriptions"
mkdir -p "$FAULT_BIN" "$FAULT_UNITS" "$FAULT_LIVE" "$FAULT_SUBS"
cat >"$FAULT_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
action="${1:-}"
if [[ "$action" == "is-active" || "$action" == "is-enabled" ]]; then
  [[ "$*" == *"etxr-xray.service"* ]]
  exit
fi
if [[ "$action" == "restart" && "$*" == *"etxr-xray.service"* ]]; then
  if [[ ! -e "${ETXR_TEST_XRAY_FAILED:?}" ]]; then
    : >"$ETXR_TEST_XRAY_FAILED"
    exit 1
  fi
fi
exit 0
EOF
cat >"$FAULT_BIN/chown" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$FAULT_BIN/systemctl" "$FAULT_BIN/chown"
FAULT_PRELOAD_ENV=()
if (( EUID != 0 )); then
  need gcc
  cat >"$FAULT/fakeuid.c" <<'EOF'
#include <sys/types.h>
uid_t getuid(void) { return 0; }
uid_t geteuid(void) { return 0; }
int getresuid(uid_t *r, uid_t *e, uid_t *s) {
  if (r) *r = 0;
  if (e) *e = 0;
  if (s) *s = 0;
  return 0;
}
EOF
  gcc -shared -fPIC "$FAULT/fakeuid.c" -o "$FAULT/fakeuid.so"
  FAULT_PRELOAD_ENV=("LD_PRELOAD=$FAULT/fakeuid.so")
fi
printf 'old unit\n' >"$FAULT_UNITS/etxr-xray.service"
printf 'old xray\n' >"$FAULT_LIVE/xray.json"
printf 'old subscription\n' >"$FAULT_SUBS/old"
FAULT_STATE="$FAULT/state.json"
FAULT_ENV=(
  "ETXR_STATE=$FAULT_STATE"
  "ETXR_RUNTIME=$FAULT"
  "ETXR_GENERATED=$FAULT/generated"
  "ETXR_SUBSCRIPTIONS=$FAULT_SUBS"
  "ETXR_SYSTEMD_UNIT_DIR=$FAULT_UNITS"
  "ETXR_WAIT_IP_HELPER=$FAULT/wait-ip"
  "XRAY_BIN=$XRAY"
  "SING_BOX_BIN=$SING_BOX"
)
env "${FAULT_ENV[@]}" "$EDGE" init --name rollback --role gateway \
  --domain rollback.example.com --address rollback.example.com \
  --nginx-mode disabled --xray-config "$FAULT_LIVE/xray.json" \
  --sing-box-config "$FAULT_LIVE/sing-box.json" >/dev/null
env "${FAULT_ENV[@]}" "$EDGE" user add --name rollback-user \
  --uuid 55555555-5555-4555-8555-555555555555 --password ROLLBACK >/dev/null
env "${FAULT_ENV[@]}" "$EDGE" route add --name rollback-route \
  --path /rollback --port 18101 --target direct >/dev/null
env "${FAULT_ENV[@]}" "$EDGE" render >/dev/null
if env "${FAULT_ENV[@]}" \
   "ETXR_TEST_XRAY_FAILED=$FAULT/xray-restart-failed" \
   "${FAULT_PRELOAD_ENV[@]}" \
   "PATH=$FAULT_BIN:$PATH" \
   "$EDGE" apply >/dev/null 2>&1; then
  echo "apply unexpectedly succeeded after injected Xray restart failure" >&2
  exit 1
fi
grep -q '^old xray$' "$FAULT_LIVE/xray.json"
grep -q '^old subscription$' "$FAULT_SUBS/old"
grep -q '^old unit$' "$FAULT_UNITS/etxr-xray.service"
[[ ! -e "$FAULT_UNITS/etxr-sing-box.service" ]]

"$JQ" -e '.inbounds | length == 6' "$TMP/generated/xray.json" >/dev/null
"$JQ" -e '.users[] | select(
  .name == "alice" and
  .speed_limit.up_mbps == 5 and
  .speed_limit.down_mbps == 20
)' "$TMP/state.json" >/dev/null
"$JQ" -e '.users[] | select(
  .name == "alice" and .up_mbps == 5 and .down_mbps == 20
)' "$TMP/generated/limits.json" >/dev/null
"$JQ" -e '.outbounds[] | select(
  .tag == "limit-socks-alice" and
  .settings.servers[0].address == "127.0.0.1" and
  .settings.servers[0].port == 18181
)' "$TMP/generated/xray.json" >/dev/null
"$JQ" -e '.routing.rules[] | select(
  .user == ["alice@hk"] and .outboundTag == "limit-direct-alice"
)' "$TMP/generated/xray.json" >/dev/null
"$JQ" -e '.outbounds[] | select(
  .tag == "hy2-bridge-alice" and .server_port == 18183
)' "$TMP/generated/sing-box.json" >/dev/null
"$JQ" -e '.route.rules[] | select(
  .auth_user == ["alice"] and .outbound == "hy2-bridge-alice"
)' "$TMP/generated/sing-box.json" >/dev/null
"$JQ" -e '.routing.rules[] | select(.protocol == ["bittorrent"])' \
  "$TMP/generated/xray.json" >/dev/null
"$JQ" -e '.route.rules[] | select(.protocol == "bittorrent" and .action == "reject")' \
  "$TMP/generated/sing-box.json" >/dev/null

# Live HY2 -> local VLESS bridge -> Xray -> authenticated limiter -> target.
HTTP_PORT="$(free_tcp_port)"
SOCKS_PORT="$(free_tcp_port)"
mkdir -p "$TMP/web"
printf 'etxr protocol e2e\n' >"$TMP/web/index.html"
python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 \
  --directory "$TMP/web" >"$TMP/http.log" 2>&1 &
TEST_PIDS+=("$!")
"$DATAPLANE_BIN" limiter --config "$TMP/generated/limits.json" \
  >"$TMP/limiter.log" 2>&1 &
TEST_PIDS+=("$!")
"$XRAY" run -config "$TMP/generated/xray.json" >"$TMP/xray-live.log" 2>&1 &
TEST_PIDS+=("$!")
"$SING_BOX" run -c "$TMP/generated/sing-box.json" \
  >"$TMP/sing-server.log" 2>&1 &
TEST_PIDS+=("$!")
cat >"$TMP/sing-client.json" <<EOF
{
  "log": {"level": "warn"},
  "inbounds": [{
    "type": "socks",
    "tag": "socks-in",
    "listen": "127.0.0.1",
    "listen_port": ${SOCKS_PORT}
  }],
  "outbounds": [{
    "type": "hysteria2",
    "tag": "hy2-out",
    "server": "127.0.0.1",
    "server_port": 8443,
    "password": "HY2PASS",
    "obfs": {"type": "salamander", "password": "OBFSPASS"},
    "tls": {
      "enabled": true,
      "server_name": "hk.example.com",
      "insecure": true
    }
  }],
  "route": {"final": "hy2-out"}
}
EOF
"$SING_BOX" check -c "$TMP/sing-client.json"
"$SING_BOX" run -c "$TMP/sing-client.json" \
  >"$TMP/sing-client.log" 2>&1 &
TEST_PIDS+=("$!")
wait_tcp "$HTTP_PORT"
wait_tcp "$SOCKS_PORT"
sleep 1
curl -fsS --max-time 15 --socks5-hostname "127.0.0.1:${SOCKS_PORT}" \
  "http://127.0.0.1:${HTTP_PORT}/" | grep -Fq 'etxr protocol e2e'
"$DATAPLANE_BIN" meter --state "$TMP/state.json" \
  --usage-file "$TMP/usage.json" --xray-bin "$XRAY" --once
"$JQ" -e '.users.alice |
  (.uplink > 0) and (.downlink > 0)
' "$TMP/usage.json" >/dev/null
stop_test_processes

"$EDGE" subscription alice >"$TMP/subscription.txt"
grep -Eq 'Subscription URL: https://hk\.example\.com/522b276a/[0-9a-f]{40}$' \
  "$TMP/subscription.txt"
if grep -q '/sub/' "$TMP/subscription.txt"; then
  echo "fixed /sub/ subscription URL exists" >&2
  exit 1
fi
"$EDGE" client alice --route pq --out "$TMP/client-pq.json"
"$XRAY" run -test -config "$TMP/client-pq.json"
grep -q 'flow=xtls-rprx-vision' "$TMP/subscription.txt"
grep -q 'security=reality' "$TMP/subscription.txt"
grep -q '^hysteria2://' "$TMP/subscription.txt"

# Master/worker one-ID pairing, public RAW primary plus EasyTier fallback.
"$EDGE" cluster master-init --ip 10.100.0.1 --endpoint 192.0.2.10 --port 11010
"$JQ" -e '.easytier.public_endpoint == "192.0.2.10"' "$TMP/state.json" >/dev/null
"$EDGE" pair create --name b1 --public-host b1.example.com \
  --public-relay-port 30001 --public-listen-port 29000 \
  --xhttp-enabled --xhttp-port 30443 --xhttp-listen-port 30443 \
  --xhttp-path /b1-direct-xhttp \
  --reality-port 18443 --hy2-port 28443 >"$TMP/pair-create.txt"
PAIR_ID="$(cat "$TMP/pairs/b1.id")"
PAIR_FINGERPRINT="$(awk '/Pair 签名指纹/ {print $NF}' "$TMP/pair-create.txt")"
[[ "$PAIR_FINGERPRINT" =~ ^[0-9A-F]{32}$ ]]

# A wrong out-of-band fingerprint must fail before worker state is created.
BAD_WORKER="$TMP/bad-worker"
if ETXR_STATE="$BAD_WORKER/state.json" \
   ETXR_RUNTIME="$BAD_WORKER" \
   ETXR_GENERATED="$BAD_WORKER/generated" \
   ETXR_SUBSCRIPTIONS="$BAD_WORKER/subscriptions" \
   XRAY_BIN="$XRAY" SING_BOX_BIN="$SING_BOX" \
   "$EDGE" pair join --prepare-only \
     --fingerprint 00000000000000000000000000000000 \
     "$PAIR_ID" >/dev/null 2>&1; then
  echo "pair join unexpectedly accepted a wrong fingerprint" >&2
  exit 1
fi
[[ ! -e "$BAD_WORKER/state.json" ]]

# Recomputing the transport checksum cannot make a modified signature valid.
IFS='.' read -r pair_prefix pair_payload pair_public pair_signature _pair_checksum \
  <<<"$PAIR_ID"
if [[ "${pair_signature:0:1}" == "A" ]]; then
  tampered_signature="B${pair_signature:1}"
else
  tampered_signature="A${pair_signature:1}"
fi
tampered_checksum="$(printf '%s.%s.%s' \
  "$pair_payload" "$pair_public" "$tampered_signature" |
  sha256sum | awk '{print substr($1,1,24)}')"
TAMPERED_PAIR="${pair_prefix}.${pair_payload}.${pair_public}.${tampered_signature}.${tampered_checksum}"
if "$EDGE" pair decode --fingerprint "$PAIR_FINGERPRINT" \
  "$TAMPERED_PAIR" >/dev/null 2>&1; then
  echo "pair decode unexpectedly accepted a modified signature" >&2
  exit 1
fi

"$EDGE" pair decode "$PAIR_ID" |
  "$JQ" -e '
    .version == 2 and
    .worker.name == "b1" and
    .master.address == "192.0.2.10" and
    .relay.public_port == 30001 and
    .relay.listen_port == 29000 and
    .direct.xhttp.enabled == true and
    .direct.xhttp.public_port == 30443 and
    (.control.base_url | test("^https://hk\\.example\\.com/[0-9a-f]{32}$")) and
    .control.node_id == "b1" and
    (.control.token | test("^[0-9a-f]{64}$"))
  ' >/dev/null
PAIR_EXPIRES_AT="$("$EDGE" pair decode "$PAIR_ID" | "$JQ" -r '.expires_at')"
PAIR_REMAINING="$((PAIR_EXPIRES_AT - $(date +%s)))"
(( PAIR_REMAINING >= 1700 && PAIR_REMAINING <= 1800 ))
"$EDGE" render
"$XRAY" run -test -config "$TMP/generated/xray.json"
CONTROL_PATH="$("$JQ" -r '.control.base_path' "$TMP/state.json")"
[[ "$CONTROL_PATH" =~ ^/[0-9a-f]{32}$ ]]
grep -Fq "location ^~ ${CONTROL_PATH}/" "$TMP/generated/nginx-paths.conf"
grep -Fq 'proxy_pass http://127.0.0.1:18180/;' "$TMP/generated/nginx-paths.conf"
"$JQ" -e '
  .node_id == "b1" and
  (.version | test("^[0-9a-f]{64}$")) and
  (.users | map(.name) | index("alice") != null)
' "$TMP/control/nodes/b1.json" >/dev/null
"$JQ" -e '.xray.exits[] | select(
  .name == "b1" and
  .address == "b1.example.com" and .port == 30001 and
  .backup_address == "10.100.0.11" and .backup_port == 19000 and
  .connection_preference == "public-primary"
)' "$TMP/state.json" >/dev/null
"$JQ" -e '.routing.balancers[] | select(.tag == "failover-b1")' \
  "$TMP/generated/xray.json" >/dev/null
"$JQ" -e '.routing.balancers[] | select(.tag == "limit-failover-alice-b1")' \
  "$TMP/generated/xray.json" >/dev/null
"$JQ" -e '.outbounds[] | select(
  .tag == "exit-b1-primary" and
  .settings.vnext[0].address == "b1.example.com" and
  .streamSettings.network == "raw"
)' "$TMP/generated/xray.json" >/dev/null
"$JQ" -e '.outbounds[] | select(
  .tag == "exit-b1-backup" and .settings.vnext[0].address == "10.100.0.11"
)' "$TMP/generated/xray.json" >/dev/null
"$JQ" -e '.observatory.subjectSelector | index("exit-b1-primary") != null' \
  "$TMP/generated/xray.json" >/dev/null

# A worker without a public relay uses EasyTier only.
"$EDGE" pair create --name b2 --no-xhttp --no-reality --no-hy2 \
  --private-relay-port 19001 >"$TMP/pair-create-b2.txt"
"$JQ" -e '.xray.exits[] | select(
  .name == "b2" and
  .address == "10.100.0.12" and .port == 19001 and
  .backup_address == "" and
  .connection_preference == "easytier-only"
)' "$TMP/state.json" >/dev/null

WORKER="$TMP/worker"
ETXR_STATE="$WORKER/state.json" \
ETXR_RUNTIME="$WORKER" \
ETXR_GENERATED="$WORKER/generated" \
ETXR_SUBSCRIPTIONS="$WORKER/subscriptions" \
XRAY_BIN="$XRAY" SING_BOX_BIN="$SING_BOX" \
  "$EDGE" pair join --prepare-only --fingerprint "$PAIR_FINGERPRINT" \
    "$PAIR_ID" >"$TMP/pair-join.txt"
"$XRAY" run -test -config "$WORKER/generated/xray.json"
"$SING_BOX" check -c "$WORKER/generated/sing-box.json"
"$JQ" -e '.inbounds | map(select(.tag | startswith("relay-"))) | length == 2' \
  "$WORKER/generated/xray.json" >/dev/null
"$JQ" -e '.inbounds[] | select(
  .tag == "relay-b1-public" and .port == 29000
)' "$WORKER/generated/xray.json" >/dev/null
"$JQ" -e '.inbounds[] | select(
  .tag == "path-b1-xhttp" and
  .port == 30443 and
  .streamSettings.security == "tls"
)' "$WORKER/generated/xray.json" >/dev/null
"$JQ" -e '.easytier.peer == "192.0.2.10:11010"' "$WORKER/state.json" >/dev/null
"$JQ" -e '
  (.xray.routes[] | select(.name == "b1-xhttp") | .allow_insecure) == true and
  .hysteria2.insecure == true
' "$WORKER/state.json" >/dev/null
openssl x509 -in "$WORKER/certs/b1/fullchain.pem" -noout -ext subjectAltName |
  grep -Fq 'DNS:b1.example.com'
"$JQ" -e '
  .control.enabled == false and
  .control.agent.enabled == true and
  .control.agent.node_id == "b1" and
  (.control.agent.base_url | test("^https://hk\\.example\\.com/[0-9a-f]{32}$")) and
  (.control.agent.token | test("^[0-9a-f]{64}$"))
' "$WORKER/state.json" >/dev/null
ETXR_STATE="$WORKER/state.json" \
ETXR_RUNTIME="$WORKER" \
ETXR_GENERATED="$WORKER/generated" \
ETXR_SUBSCRIPTIONS="$WORKER/subscriptions" \
XRAY_BIN="$XRAY" SING_BOX_BIN="$SING_BOX" \
  "$EDGE" validate >/dev/null

# Invalid control-plane user data must be rejected without changing state.
cp "$WORKER/state.json" "$TMP/worker-state-before-invalid-control.json"
BAD_CONTROL_USERS="$("$JQ" '.users[0].subscription_token = "../../etc/passwd"' \
  "$TMP/state.json")"
if printf '%s\n' "$BAD_CONTROL_USERS" |
   ETXR_STATE="$WORKER/state.json" \
   ETXR_RUNTIME="$WORKER" \
   ETXR_GENERATED="$WORKER/generated" \
   ETXR_SUBSCRIPTIONS="$WORKER/subscriptions" \
   XRAY_BIN="$XRAY" SING_BOX_BIN="$SING_BOX" \
   "$EDGE" control apply --prepare-only >/dev/null 2>&1; then
  echo "control apply unexpectedly accepted an unsafe subscription token" >&2
  exit 1
fi
cmp "$WORKER/state.json" "$TMP/worker-state-before-invalid-control.json"

# Semantic validation rejects malformed overlay addresses and TCP port overlap.
SEMANTIC="$TMP/semantic"
mkdir -p "$SEMANTIC"
cp "$WORKER/state.json" "$SEMANTIC/state.json"
"$JQ" '
  .easytier.ipv4 = "10.100.0.999" |
  .xray.reality_inbounds[0].port = .xray.relay_inbounds[0].port
' "$SEMANTIC/state.json" >"$SEMANTIC/state.invalid.json"
mv "$SEMANTIC/state.invalid.json" "$SEMANTIC/state.json"
if ETXR_STATE="$SEMANTIC/state.json" \
   ETXR_RUNTIME="$SEMANTIC" \
   ETXR_GENERATED="$SEMANTIC/generated" \
   ETXR_SUBSCRIPTIONS="$SEMANTIC/subscriptions" \
   XRAY_BIN="$XRAY" SING_BOX_BIN="$SING_BOX" \
   "$EDGE" validate >/dev/null 2>&1; then
  echo "validate unexpectedly accepted invalid EasyTier IP and duplicate TCP ports" >&2
  exit 1
fi

# Concurrent state updates are serialized and retain every unique user.
CONCURRENT="$TMP/concurrent"
mkdir -p "$CONCURRENT"
cp "$WORKER/state.json" "$CONCURRENT/state.json"
concurrent_pids=()
for i in $(seq 1 12); do
  ETXR_STATE="$CONCURRENT/state.json" \
  ETXR_RUNTIME="$CONCURRENT" \
  ETXR_GENERATED="$CONCURRENT/generated" \
  ETXR_SUBSCRIPTIONS="$CONCURRENT/subscriptions" \
  XRAY_BIN="$XRAY" SING_BOX_BIN="$SING_BOX" \
    "$EDGE" user add --name "concurrent-$i" \
      --uuid "44444444-4444-4444-8444-$(printf '%012d' "$i")" \
      --password "PASS-$i" >/dev/null 2>&1 &
  concurrent_pids+=("$!")
done
for pid in "${concurrent_pids[@]}"; do
  wait "$pid"
done
"$JQ" -e '
  [.users[] | select(.name | startswith("concurrent-"))] | length == 12
' "$CONCURRENT/state.json" >/dev/null

# A signed control-plane payload can be applied atomically on the worker.
CONTROL_USERS="$("$JQ" '.users + [{
  name: "bob",
  uuid: "33333333-3333-4333-8333-333333333333",
  hy2_password: "BOBPASS",
  enabled: true,
  expires_at: null,
  routes: ["*"],
  subscription_prefix: "48181acd",
  subscription_token: "0123456789012345678901234567890123456789"
}]' "$TMP/state.json")"
printf '%s\n' "$CONTROL_USERS" |
  ETXR_STATE="$WORKER/state.json" \
  ETXR_RUNTIME="$WORKER" \
  ETXR_GENERATED="$WORKER/generated" \
  ETXR_SUBSCRIPTIONS="$WORKER/subscriptions" \
  XRAY_BIN="$XRAY" SING_BOX_BIN="$SING_BOX" \
  "$EDGE" control apply --prepare-only
"$JQ" -e '.users | map(.name) | index("bob") != null' "$WORKER/state.json" >/dev/null
"$XRAY" run -test -config "$WORKER/generated/xray.json"
"$SING_BOX" check -c "$WORKER/generated/sing-box.json"

printf 'runtime-test: PASS (Xray %s, sing-box %s)\n' \
  "$("$XRAY" version | head -n1)" "$("$SING_BOX" version | head -n1)"
