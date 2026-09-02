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

export ETXR_STATE="$TMP/state.json"
export ETXR_RUNTIME="$TMP/runtime"
export ETXR_GENERATED="$TMP/runtime/generated"
export ETXR_BACKUPS="$TMP/runtime/backups"
export ETXR_SUBSCRIPTIONS="$TMP/subscriptions"
export ETXR_USAGE_FILE="$TMP/usage.json"
export ETXR_DOMAIN_FILE="$TMP/domains.json"
export ETXR_PAIR_KEY_DIR="$TMP/keys"
export ETXR_PAIR_PRIVATE_KEY="$TMP/keys/pair-signing.key"
export ETXR_PAIR_PUBLIC_KEY="$TMP/keys/pair-signing.pub"

mkdir -p "$TMP/tools" "$ETXR_RUNTIME"
cat >"$TMP/tools/ufw" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "status" ]]; then
  echo 'Status: active'
  exit 0
fi
printf '%s\n' "\$*" >>"$TMP/ufw.log"
EOF
chmod 755 "$TMP/tools/ufw"
PATH="$TMP/tools:$PATH"
export PATH

# shellcheck source=etxr.sh
source "$ROOT/etxr.sh"

jq -n '
  {
    node: {name: "worker", role: "exit", domain: "worker.example.com", address: "worker.example.com"},
    nginx: {mode: "snippet"},
    xray: {
      routes: [
        {
          name: "behind-nginx",
          listen: "127.0.0.1",
          port: 18000,
          direct: true
        },
        {
          name: "public",
          listen: "0.0.0.0",
          port: 18443,
          direct: true
        }
      ],
      relay_inbounds: [],
      reality_inbounds: []
    },
    easytier: {enabled: false},
    hysteria2: {enabled: false}
  }
' >"$ETXR_STATE"

printf '18000\ttcp\n' >"$ETXR_RUNTIME/ufw-rules.tsv"
configure_ufw_from_state

ufw_log="$(tr -d '\r' <"$TMP/ufw.log")"
ufw_state="$(tr -d '\r' <"$ETXR_RUNTIME/ufw-rules.tsv")"
grep -Fq 'delete allow 18000/tcp' <<<"$ufw_log"
if grep -Fq 'allow 18000/tcp' < <(grep -v '^delete ' <<<"$ufw_log"); then
  echo "UFW unexpectedly allowed loopback-only XHTTP port 18000" >&2
  exit 1
fi
grep -Fq 'allow 18443/tcp' <<<"$ufw_log"
[[ "$ufw_state" == $'18443\ttcp' ]]

printf 'ufw-test: PASS\n'
