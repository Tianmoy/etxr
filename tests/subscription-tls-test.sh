#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export ETXR_STATE="$TMP/state.json"
export ETXR_RUNTIME="$TMP/runtime"
export ETXR_GENERATED="$TMP/generated"
export ETXR_SUBSCRIPTIONS="$TMP/subscriptions"
export ETXR_CONTROL_DIR="$TMP/control"

EDGE="$ROOT/etxr.sh"

"$EDGE" init --name master --role gateway \
  --domain master.example.com --address master.example.com \
  --nginx-mode disabled >/dev/null
"$EDGE" user add --name alice \
  --uuid 11111111-1111-4111-8111-111111111111 \
  --password TEST-PASSWORD >/dev/null
"$EDGE" route add --name master --path /master-path \
  --port 18001 --target direct >/dev/null

"$EDGE" subscriptions snapshot >"$TMP/master-entry.json"
jq -e 'all(.xray.routes[]; .security == "tls")' \
  "$TMP/master-entry.json" >/dev/null

jq '.paired_nodes = [{name: "worker"}]' "$ETXR_STATE" \
  >"$TMP/state.next.json"
mv "$TMP/state.next.json" "$ETXR_STATE"
mkdir -p "$ETXR_CONTROL_DIR/reports"
jq -n '{
  status: "current",
  entry: {
    schema: 1,
    node: {
      name: "worker",
      domain: "worker.example.com",
      address: "worker.example.com"
    },
    nginx: {tls_port: 443},
    xray: {
      routes: [{
        name: "worker-xhttp",
        path: "/worker-path",
        port: 18000,
        public_port: 443,
        target: "direct",
        profile: "plain",
        host: "",
        client_encryption: "none",
        flow: "",
        security: "none",
        direct: true
      }],
      reality_inbounds: []
    },
    hysteria2: {
      enabled: false,
      port: 443,
      obfs: "none",
      obfs_password: "",
      insecure: false
    }
  }
}' >"$ETXR_CONTROL_DIR/reports/worker.json"

"$EDGE" subscription alice >"$TMP/subscription.txt"
worker_link="$(grep -F '#worker-XHTTP' "$TMP/subscription.txt")"
[[ "$worker_link" == *'security=tls'* ]]
[[ "$worker_link" != *'security=none'* ]]
"$EDGE" client alice --route master \
  --out "$TMP/client.json" >/dev/null
jq -e '.outbounds[0].streamSettings.tlsSettings |
  has("pinnedPeerCertSha256") | not' "$TMP/client.json" >/dev/null

jq '.subscription.enabled = true' "$ETXR_STATE" >"$TMP/state.next.json"
mv "$TMP/state.next.json" "$ETXR_STATE"
"$EDGE" render >/dev/null
token="$(jq -r '.users[] | select(.name == "alice") |
  .subscription_token' "$ETXR_STATE")"
clash="$ETXR_GENERATED/subscriptions/${token}.yaml"
plain_file="$ETXR_GENERATED/subscriptions/${token}"
[[ -s "$clash" ]]
[[ -s "$plain_file" ]]
grep -q 'name: "master-XHTTP"' "$clash"
grep -q 'name: "worker-XHTTP"' "$clash"
# every proxy entry must start its own line (multi-source join regression)
[[ "$(grep -cE '^  - \{name: "[^"]*", type: (vless|hysteria2)' "$clash")" -eq 2 ]]
grep -q 'network: xhttp' "$clash"
grep -q 'servername: "worker.example.com"' "$clash"
grep -q 'proxy-groups:' "$clash"
grep -q 'name: 🚀 节点选择' "$clash"
grep -q 'RULE-SET,cn_domain,DIRECT' "$clash"
grep -q 'MATCH,🌐 国外流量' "$clash"
# AI rules via rule-set, Steam downloads direct, fallback defaults to proxy
grep -q 'RULE-SET,ai_domain,🤖 AI 服务' "$clash"
grep -q 'rule-providers:' "$clash"
grep -q 'DOMAIN-SUFFIX,steamcontent.com,🎯 全球直连' "$clash"
grep -A 3 'name: 🌐 国外流量' "$clash" | grep -q '🚀 节点选择'
# service switch groups and auto-test group are gone
[[ "$(grep -c '⚡ 自动测速' "$clash")" -eq 0 ]]
[[ "$(grep -c 'name: GitHub' "$clash")" -eq 0 ]]

echo "subscription-tls-test: PASS"
