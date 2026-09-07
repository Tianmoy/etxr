#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export ETXR_STATE="$TMP/state.json"
export ETXR_RUNTIME="$TMP/runtime"
export ETXR_GENERATED="$TMP/generated"
export ETXR_SUBSCRIPTIONS="$TMP/subscriptions"

ip() {
  case "$1 $2" in
    'route show') printf '%s\n' 'default via 192.0.2.254 dev eth0' ;;
    'route get') printf '%s\n' '198.51.100.10 via 192.0.2.254 dev eth0 src 198.51.100.10' ;;
    '-4 -o')
      if [[ "$5" == scope ]]; then
        :
      else
        [[ "$6" == eth0 ]] || return 1
      fi
      printf '%s\n' \
        '2: eth0 inet 198.51.100.10/24 brd 198.51.100.255 scope global eth0' \
        '2: eth0 inet 198.51.100.11/24 brd 198.51.100.255 scope global eth0' \
        '2: eth0 inet 198.51.100.12/24 brd 198.51.100.255 scope global eth0' \
        '2: eth0 inet 198.51.101.13/24 brd 198.51.101.255 scope global eth0'
      ;;
    *) return 1 ;;
  esac
}

getent() {
  [[ "$1 $2" == 'ahostsv4 multi.example.com' ]] || return 2
  printf '%s\n' '198.51.100.11 STREAM multi.example.com'
}

# shellcheck source=etxr.sh
source "$ROOT/etxr.sh"

is_public_ipv4 198.51.100.10 ||
  { echo 'public IPv4 classification failed' >&2; exit 1; }

mapfile -t candidates < <(public_ipv4_candidates)
[[ "${candidates[*]}" == '198.51.100.10 198.51.100.11 198.51.100.12' ]]

is_public_ipv4 198.51.100.11
if is_public_ipv4 10.1.2.3; then exit 1; fi
if is_public_ipv4 192.168.1.3; then exit 1; fi
if is_public_ipv4 100.64.1.3; then exit 1; fi
if is_public_ipv4 169.254.1.3; then exit 1; fi

valid_inbound_listen_address 198.51.100.11
if valid_inbound_listen_address 203.0.113.99; then exit 1; fi

[[ "$(local_ipv4_for_address multi.example.com)" == 198.51.100.11 ]]
[[ "$(local_ipv4_for_address 198.51.100.12)" == 198.51.100.12 ]]

address="$(printf '1\n' | prompt_domain_or_public_ip_value \
  '测试连接地址' multi.example.com 2>"$TMP/address-prompt")"
[[ "$address" == 198.51.100.10 ]]
grep -Fq '检测到多个同网段公网 IPv4' "$TMP/address-prompt"

address="$(printf '\n' | prompt_domain_or_public_ip_value \
  '测试连接地址' multi.example.com 2>/dev/null)"
[[ "$address" == multi.example.com ]]

listen="$(printf '2\n' | prompt_inbound_listen_address \
  '测试监听地址' 198.51.100.11 2>"$TMP/listen-prompt")"
[[ "$listen" == 198.51.100.11 ]]
grep -Fq '指定其中一个可固定“该 IP 入、该 IP 出”' "$TMP/listen-prompt"

listen="$(printf '\n' | prompt_inbound_listen_address \
  '测试监听地址' 198.51.100.11 2>/dev/null)"
[[ "$listen" == 198.51.100.11 ]]

listen="$(printf '0\n' | prompt_inbound_listen_address \
  '测试监听地址' 198.51.100.11 2>/dev/null)"
[[ "$listen" == 0.0.0.0 ]]

endpoint="$(printf '0\n' | prompt_public_endpoint_value \
  '测试主从地址' 198.51.100.10 multi.example.com 2>"$TMP/endpoint-prompt")"
[[ "$endpoint" == 198.51.100.10 ]]
grep -Fq '检测到多个公网 IPv4' "$TMP/endpoint-prompt"

entry="$(printf '0\n' | prompt_public_entry_config multi.example.com \
  2>"$TMP/entry-prompt")"
IFS=$'\t' read -r entry_address entry_listen <<<"$entry"
[[ "$entry_address" == multi.example.com ]]
[[ "$entry_listen" == 198.51.100.11 ]]
grep -Fq '198.51.100.11 入、198.51.100.11 出' "$TMP/entry-prompt"

entry="$(printf '1\n' | prompt_public_entry_config multi.example.com 2>/dev/null)"
IFS=$'\t' read -r entry_address entry_listen <<<"$entry"
[[ "$entry_address" == multi.example.com ]]
[[ "$entry_listen" == 0.0.0.0 ]]

entry="$(printf '2\n' | prompt_public_entry_config multi.example.com 2>/dev/null)"
IFS=$'\t' read -r entry_address entry_listen <<<"$entry"
[[ "$entry_address" == 198.51.100.10 ]]
[[ "$entry_listen" == 198.51.100.10 ]]

printf 'public-ip-test: PASS\n'
