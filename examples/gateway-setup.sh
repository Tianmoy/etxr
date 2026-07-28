#!/usr/bin/env bash
set -Eeuo pipefail

# Replace every uppercase placeholder before running.
EDGE=/usr/local/sbin/etxr

"$EDGE" init \
  --name hk \
  --role gateway \
  --domain HK_DOMAIN \
  --address HK_DOMAIN \
  --nginx-mode standalone \
  --cert /etc/letsencrypt/live/HK_DOMAIN/fullchain.pem \
  --key /etc/letsencrypt/live/HK_DOMAIN/privkey.pem

"$EDGE" user add --name USER_A

# Exit credentials must match the VLESS inbound created on each exit node.
"$EDGE" exit add \
  --name tw \
  --address TW_DOMAIN \
  --port 443 \
  --transport tls \
  --server-name TW_DOMAIN \
  --host TW_DOMAIN \
  --path /TW_RELAY_PATH \
  --uuid TW_RELAY_UUID

"$EDGE" exit add \
  --name us \
  --address US_DOMAIN \
  --port 443 \
  --transport tls \
  --server-name US_DOMAIN \
  --host US_DOMAIN \
  --path /US_RELAY_PATH \
  --uuid US_RELAY_UUID

"$EDGE" route add --name hk --path /HK_ENTRY_PATH --port 18001 --target direct
"$EDGE" route add --name tw --path /TW_ENTRY_PATH --port 18002 --target tw
"$EDGE" route add --name us --path /US_ENTRY_PATH --port 18003 --target us

# Hong Kong package is 30 Mbps upload / 200 Mbps download.
"$EDGE" hy2 enable --port 8443 --up-mbps 30 --down-mbps 200 \
  --obfs salamander --masquerade https://www.cloudflare.com

"$EDGE" validate
"$EDGE" apply
