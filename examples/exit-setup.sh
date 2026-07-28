#!/usr/bin/env bash
set -Eeuo pipefail

# Run separately on Taiwan and US, replacing placeholders.
EDGE=/usr/local/sbin/etxr

"$EDGE" init \
  --name EXIT_NAME \
  --role exit \
  --domain EXIT_DOMAIN \
  --address EXIT_DOMAIN \
  --nginx-mode snippet \
  --snippet /www/server/panel/vhost/nginx/extension/EXIT_DOMAIN/etxr.conf \
  --cert /www/server/panel/vhost/cert/EXIT_DOMAIN/fullchain.pem \
  --key /www/server/panel/vhost/cert/EXIT_DOMAIN/privkey.pem

# This UUID must be the relay UUID stored in the Hong Kong exit definition.
"$EDGE" user add --name hk-relay --uuid RELAY_UUID --routes relay
"$EDGE" route add --name relay --path /RELAY_PATH --port 18100 --target direct

# Optional independent public entry on the exit node.
"$EDGE" user add --name USER_A --routes direct
"$EDGE" route add --name direct --path /DIRECT_ENTRY_PATH --port 18101 --target direct

"$EDGE" validate
"$EDGE" apply
