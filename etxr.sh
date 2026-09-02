#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

VERSION="0.17.1"
ETXR_REPOSITORY="${ETXR_REPOSITORY:-Tianmoy/etxr}"
ETXR_RELEASE_API="${ETXR_RELEASE_API:-https://api.github.com/repos/${ETXR_REPOSITORY}/releases/latest}"

STATE_FILE="${ETXR_STATE:-/etc/etxr/state.json}"
RUNTIME_DIR="${ETXR_RUNTIME:-/etc/etxr}"
GENERATED_DIR="${ETXR_GENERATED:-${RUNTIME_DIR}/generated}"
BACKUP_DIR="${ETXR_BACKUPS:-${RUNTIME_DIR}/backups}"
SUBSCRIPTION_DIR="${ETXR_SUBSCRIPTIONS:-/var/lib/etxr/subscriptions}"
CONTROL_DIR="${ETXR_CONTROL_DIR:-${RUNTIME_DIR}/control}"
CONTROL_HELPER="${ETXR_CONTROL_HELPER:-/usr/local/lib/etxr/control.py}"
CONTROL_PORT="${ETXR_CONTROL_PORT:-18180}"
SELF_BIN="${ETXR_SELF_BIN:-/usr/local/sbin/etxr}"
SELF_LINK="${ETXR_SELF_LINK:-/usr/local/bin/etxr}"
DATAPLANE_BIN="${ETXR_DATAPLANE_BIN:-/usr/local/bin/etxr-dataplane}"
DATAPLANE_DOWNLOAD_BASE="${ETXR_DOWNLOAD_BASE:-https://github.com/Tianmoy/etxr/releases/download/v${VERSION}}"
LIMITER_CONFIG="${ETXR_LIMITER_CONFIG:-${RUNTIME_DIR}/live/limits.json}"
LIMITER_PORT="${ETXR_LIMITER_PORT:-18181}"
USAGE_FILE="${ETXR_USAGE_FILE:-/var/lib/etxr/usage.json}"
DOMAIN_FILE="${ETXR_DOMAIN_FILE:-/var/lib/etxr/domains.json}"
DOMAIN_SOCKET="${ETXR_DOMAIN_SOCKET:-/run/etxr/domain-audit.sock}"
XRAY_API_PORT="${ETXR_XRAY_API_PORT:-18182}"
HY2_BRIDGE_PORT="${ETXR_HY2_BRIDGE_PORT:-18183}"
SYSTEMD_UNIT_DIR="${ETXR_SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
WAIT_IP_HELPER="${ETXR_WAIT_IP_HELPER:-/usr/local/libexec/etxr-wait-ip}"
PAIR_KEY_DIR="${ETXR_PAIR_KEY_DIR:-${RUNTIME_DIR}/keys}"
PAIR_PRIVATE_KEY="${ETXR_PAIR_PRIVATE_KEY:-${PAIR_KEY_DIR}/pair-signing.key}"
PAIR_PUBLIC_KEY="${ETXR_PAIR_PUBLIC_KEY:-${PAIR_KEY_DIR}/pair-signing.pub}"
PAIR_ID_MAX_BYTES="${ETXR_PAIR_ID_MAX_BYTES:-262144}"
PAIR_BUNDLE_MAX_BYTES="${ETXR_PAIR_BUNDLE_MAX_BYTES:-1048576}"
MIGRATION_PACKAGE_MAX_BYTES="${ETXR_MIGRATION_PACKAGE_MAX_BYTES:-134217728}"
MIGRATION_KDF_ITERATIONS="${ETXR_MIGRATION_KDF_ITERATIONS:-250000}"
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
SING_BOX_BIN="${SING_BOX_BIN:-/usr/local/bin/sing-box}"
EASYTIER_CORE_BIN="${EASYTIER_CORE_BIN:-/usr/local/bin/easytier-core}"
EASYTIER_CLI_BIN="${EASYTIER_CLI_BIN:-/usr/local/bin/easytier-cli}"
EASYTIER_CONFIG="${ETXR_EASYTIER_CONFIG:-${RUNTIME_DIR}/easytier.toml}"
DRY_RUN=0
FORCE=0
YES=0
STATE_LOCK_HELD=0
STATE_LOCK_DEPTH=0
LAST_BACKUP_DIR=""
NGINX_QUIC_CHANGED=0
NGINX_TCP443_CHANGED=0
WORKER_DIRECT_CONFIG=""

if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_CYAN=$'\033[36m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN="" C_BOLD="" C_RESET=""
fi

log() { printf '[etxr] %s\n' "$*" >&2; }
warn() { printf '[etxr] WARN: %s\n' "$*" >&2; }
die() { printf '[etxr] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
etxr - Xray/XHTTP/Hysteria2 multi-node configuration manager

Global options:
  --state FILE        State file (default: /etc/etxr/state.json)
  --dry-run           Print planned privileged changes
  --force             Allow an explicitly requested takeover/conflict
  --yes               Skip confirmation prompts
  -h, --help

Commands:
  menu                Open the Chinese numbered menu
  init                Initialize a node state file
  user add|remove|list|limit|usage|reset-usage|domains|reset-domains
  domain enable|disable|show|configure
  route add|remove|list
  exit add|remove|list
  reality add|remove|list
  hy2 enable|disable|show
  keys reality|vlessenc
  render [--out DIR]
  validate
  apply
  install [--components xray,sing-box,easytier,nginx]
  subscription USER
  subscriptions refresh|snapshot
  client USER --route ROUTE [--socks-port 10808] [--out FILE]
  backup
  migration export|import
  status
  xray status|start|stop|restart|logs|follow|monitor|check-update|update
  self status|check-update|update
  cluster master-init
  pair create|join|renew|list|remove
  control apply|status
  version

Run "etxr COMMAND --help" for command-specific examples.
EOF
}

clear_screen() {
  if [[ -t 1 ]]; then
    printf '\033[2J\033[H'
  fi
}

menu_pause() {
  local _
  printf '\n%s按回车键返回菜单...%s' "$C_YELLOW" "$C_RESET"
  read -r _ || true
}

prompt_value() {
  local label="$1" default="${2:-}" value
  if [[ -n "$default" ]]; then
    read -r -p "${label} [${default}]: " value
    printf '%s' "${value:-$default}"
  else
    read -r -p "${label}: " value
    printf '%s' "$value"
  fi
}

prompt_secret() {
  local label="$1" value
  read -r -s -p "${label}: " value
  printf '\n' >&2
  printf '%s' "$value"
}

prompt_secret_default() {
  local label="$1" default="$2" value
  read -r -s -p "${label} [已生成默认值，直接回车使用]: " value
  printf '\n' >&2
  printf '%s' "${value:-$default}"
}

prompt_bool() {
  local label="$1" default="$2" answer
  if [[ "$default" == "y" ]]; then
    read -r -p "${label} [Y/n]: " answer
    [[ ! "$answer" =~ ^[Nn]$ ]] && printf 'y' || printf 'n'
  else
    read -r -p "${label} [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] && printf 'y' || printf 'n'
  fi
}

normalize_index_selection() {
  local raw="$1" count="$2" allow_empty="${3:-false}" token
  local -a selected=()
  local -A seen=()
  raw="${raw//,/ }"
  if [[ "$raw" == "0" && "$allow_empty" == "true" ]]; then
    return 0
  fi
  for token in $raw; do
    [[ "$token" =~ ^[0-9]+$ ]] || return 1
    (( 10#$token >= 1 && 10#$token <= count )) || return 1
    [[ -z "${seen[$token]:-}" ]] || continue
    seen[$token]=1
    selected+=("$((10#$token))")
  done
  (( ${#selected[@]} > 0 )) || return 1
  printf '%s' "${selected[*]}"
}

prompt_protocol_selection() {
  local default="${1:-1 3}" answer normalized
  while true; do
    printf '\n%s【选择要安装的客户端协议】%s\n' "$C_BOLD" "$C_RESET" >&2
    printf '  1. XHTTP + HTTPS\n' >&2
    printf '  2. Reality + XHTTP\n' >&2
    printf '  3. Hysteria2\n' >&2
    read -r -p "请输入编号，可多选（例如 1 3）[${default}]: " answer
    answer="${answer:-$default}"
    if normalized="$(normalize_index_selection "$answer" 3 false)"; then
      printf '%s' "$normalized"
      return
    fi
    warn "请输入 1 到 3 的编号；多个编号用空格或逗号分隔"
  done
}

valid_mbps() { [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" <= 100000 )); }
valid_url() { [[ "$1" =~ ^https?://[^[:space:]]+$ ]]; }
valid_node_key() {
  [[ "$1" == "*" ||
     "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}/(xhttp|reality)/[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ||
     "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}/hy2$ ]]
}

port_is_listening() {
  local proto="$1" port="$2"
  command -v ss >/dev/null 2>&1 || return 1
  case "$proto" in
    tcp) ss -H -lnt "sport = :$port" 2>/dev/null | grep -q . ;;
    udp) ss -H -lnu "sport = :$port" 2>/dev/null | grep -q . ;;
    *) return 1 ;;
  esac
}

port_is_nginx_owned() {
  local proto="$1" port="$2"
  command -v ss >/dev/null 2>&1 || return 1
  case "$proto" in
    tcp) ss -H -lntp "sport = :$port" 2>/dev/null ;;
    udp) ss -H -lnup "sport = :$port" 2>/dev/null ;;
    *) return 1 ;;
  esac | grep -q 'users:(("nginx"'
}

port_is_sing_box_owned() {
  local proto="$1" port="$2"
  command -v ss >/dev/null 2>&1 || return 1
  case "$proto" in
    tcp) ss -H -lntp "sport = :$port" 2>/dev/null ;;
    udp) ss -H -lnup "sport = :$port" 2>/dev/null ;;
    *) return 1 ;;
  esac | grep -q 'users:(("sing-box"'
}

wait_for_nginx_udp_release() {
  local port="$1" timeout_seconds="${2:-30}" attempt attempts
  [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || return 2
  attempts="$((10#$timeout_seconds * 2))"
  for ((attempt=0; attempt<attempts; attempt++)); do
    port_is_nginx_owned udp "$port" || return 0
    sleep 0.5
  done
  port_is_nginx_owned udp "$port" && return 1
  return 0
}

nginx_effective_config_files() {
  local nb="${ETXR_NGINX_EFFECTIVE_BIN:-}"
  [[ -z "${ETXR_NGINX_SCAN_ROOTS:-}" ]] || return 0
  if [[ -n "$nb" ]]; then
    :
  elif [[ -f "$STATE_FILE" ]] && command -v jq >/dev/null 2>&1; then
    nb="$(nginx_bin 2>/dev/null || true)"
  elif [[ -x /www/server/nginx/sbin/nginx ]]; then
    nb=/www/server/nginx/sbin/nginx
  elif [[ -x /usr/sbin/nginx ]]; then
    nb=/usr/sbin/nginx
  elif command -v nginx >/dev/null 2>&1; then
    nb="$(command -v nginx)"
  fi
  [[ -n "$nb" && -x "$nb" ]] || return 0
  "$nb" -T 2>&1 |
    sed -n 's/^# configuration file \(.*\):$/\1/p'
}

nginx_config_candidates() {
  local root candidate resolved
  local -a roots=()
  local -A seen=()
  if [[ -n "${ETXR_NGINX_SCAN_ROOTS:-}" ]]; then
    IFS=':' read -r -a roots <<<"$ETXR_NGINX_SCAN_ROOTS"
  else
    roots=(
      /www/server/nginx/conf/nginx.conf
      /www/server/panel/vhost/nginx
      /etc/nginx/nginx.conf
      /etc/nginx/conf.d
      /etc/nginx/sites-enabled
    )
  fi
  for root in "${roots[@]}"; do
    [[ -e "$root" ]] || continue
    if [[ -f "$root" ]]; then
      resolved="$(readlink -f -- "$root" 2>/dev/null || true)"
      [[ -n "$resolved" && -f "$resolved" && -z "${seen[$resolved]:-}" ]] || continue
      seen["$resolved"]=1
      printf '%s\0' "$resolved"
      continue
    fi
    [[ -d "$root" ]] || continue
    while IFS= read -r -d '' candidate; do
      resolved="$(readlink -f -- "$candidate" 2>/dev/null || true)"
      [[ -n "$resolved" && -f "$resolved" && -z "${seen[$resolved]:-}" ]] || continue
      seen["$resolved"]=1
      printf '%s\0' "$resolved"
    done < <(
      if [[ "$root" == */sites-enabled ]]; then
        find "$root" -maxdepth 1 \( -type f -o -type l \) -print0 2>/dev/null
      else
        find "$root" \( -type f -o -type l \) \
          \( -name 'nginx.conf' -o -name '*.conf' \) -print0 2>/dev/null
      fi
    )
  done
  if [[ -z "${ETXR_NGINX_SCAN_ROOTS:-}" ]]; then
    while IFS= read -r candidate; do
      [[ -n "$candidate" ]] || continue
      resolved="$(readlink -f -- "$candidate" 2>/dev/null || true)"
      [[ -n "$resolved" && -f "$resolved" &&
         -z "${seen[$resolved]:-}" ]] || continue
      seen["$resolved"]=1
      printf '%s\0' "$resolved"
    done < <(nginx_effective_config_files)
  fi
}

nginx_quic_file_has_active() {
  local file="$1"
  awk '
    function is_active(line, lower) {
      lower = tolower(line)
      if (lower ~ /^[ \t]*#/ || lower ~ /^[ \t]*$/) return 0
      if (lower ~ /^[ \t]*listen[ \t]+/ &&
          lower ~ /(^|[^0-9])443([^0-9]|$)/ &&
          lower ~ /(^|[ \t])quic([ \t;]|$)/) return 1
      if (lower ~ /^[ \t]*(http3|quic_retry|quic_gso)[ \t]+on[ \t]*;/) return 1
      if (lower ~ /^[ \t]*add_header[ \t]+alt-svc[ \t]+/ &&
          lower ~ /(h3|quic)/) return 1
      return 0
    }
    is_active($0) { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

nginx_quic_active_manifest() {
  local manifest="$1" candidate
  : >"$manifest"
  while IFS= read -r -d '' candidate; do
    if nginx_quic_file_has_active "$candidate"; then
      printf '%s\0' "$candidate" >>"$manifest"
    fi
  done < <(nginx_config_candidates)
}

nginx_quic_has_active() {
  local manifest
  manifest="$(mktemp)"
  nginx_quic_active_manifest "$manifest"
  if [[ -s "$manifest" ]]; then
    rm -f "$manifest"
    return 0
  fi
  rm -f "$manifest"
  return 1
}

nginx_quic_rewrite_file() {
  local file="$1" tmp output
  tmp="$(mktemp "$(dirname "$file")/.etxr-nginx.XXXXXX")"
  output="$(mktemp "$(dirname "$file")/.etxr-nginx-output.XXXXXX")"
  if ! awk '
    function indent_of(line) {
      match(line, /^[ \t]*/)
      return substr(line, RSTART, RLENGTH)
    }
    {
      line = $0
      lower = tolower(line)
      if (lower ~ /^[ \t]*#/ || lower ~ /^[ \t]*$/) {
        print line
        next
      }
      if (lower ~ /^[ \t]*listen[ \t]+/ &&
          lower ~ /(^|[^0-9])443([^0-9]|$)/ &&
          lower ~ /(^|[ \t])quic([ \t;]|$)/) {
        indent = indent_of(line)
        print indent "# etxr-hy2-udp443: " substr(line, length(indent) + 1)
        next
      }
      if (lower ~ /^[ \t]*(http3|quic_retry|quic_gso)[ \t]+on[ \t]*;/) {
        sub(/[ \t]+on[ \t]*;/, " off;", line)
        print line " # etxr-hy2-udp443: was on"
        next
      }
      if (lower ~ /^[ \t]*add_header[ \t]+alt-svc[ \t]+/ &&
          lower ~ /(h3|quic)/) {
        indent = indent_of(line)
        print indent "# etxr-hy2-udp443: " substr(line, length(indent) + 1)
        next
      }
      print line
    }
  ' "$file" >"$output"; then
    rm -f "$tmp" "$output"
    return 2
  fi
  if cmp -s "$file" "$output"; then
    rm -f "$tmp" "$output"
    return 1
  fi
  rm -f "$tmp"
  cp -a -- "$file" "$tmp" || {
    rm -f "$tmp" "$output"
    return 2
  }
  cat "$output" >"$tmp" || {
    rm -f "$tmp" "$output"
    return 2
  }
  rm -f "$output"
  mv -f -- "$tmp" "$file"
}

nginx_quic_backup_file() {
  local file="$1" backup="$2" key
  key="$(printf '%s' "$file" | sha256sum | awk '{print $1}')"
  mkdir -p "$backup/files"
  cp -a -- "$file" "$backup/files/$key"
  printf '%s\0' "$file" >>"$backup/manifest"
}

nginx_quic_disable_manifest() {
  local manifest="$1" backup="$2" file rc
  NGINX_QUIC_CHANGED=0
  mkdir -p "$backup"
  : >"$backup/manifest"
  while IFS= read -r -d '' file; do
    nginx_quic_backup_file "$file" "$backup"
    if nginx_quic_rewrite_file "$file"; then
      NGINX_QUIC_CHANGED=1
    else
      rc=$?
      (( rc == 1 )) || return "$rc"
    fi
  done <"$manifest"
}

nginx_quic_restore_backup() {
  local backup="$1" file key tmp
  [[ -f "$backup/manifest" ]] || return 0
  while IFS= read -r -d '' file; do
    key="$(printf '%s' "$file" | sha256sum | awk '{print $1}')"
    [[ -e "$backup/files/$key" ]] || return 1
    ensure_parent "$file"
    tmp="$(mktemp "$(dirname "$file")/.etxr-restore.XXXXXX")"
    rm -f "$tmp"
    cp -a -- "$backup/files/$key" "$tmp"
    mv -f -- "$tmp" "$file"
  done <"$backup/manifest"
}

nginx_tcp443_file_has_active() {
  local file="$1"
  awk '
    {
      lower = tolower($0)
      if (lower ~ /^[ \t]*#/ || lower ~ /^[ \t]*$/) next
      if (lower ~ /^[ \t]*listen[ \t]+(0\.0\.0\.0:)?443([ \t;]|$)/ &&
          lower !~ /(^|[ \t])quic([ \t;]|$)/) {
        found = 1
        exit
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

nginx_tcp443_active_manifest() {
  local manifest="$1" candidate
  : >"$manifest"
  while IFS= read -r -d '' candidate; do
    if [[ -z "${ETXR_NGINX_SCAN_ROOTS:-}" ]]; then
      [[ "$candidate" == /www/server/panel/vhost/nginx/* ]] || continue
      [[ "$candidate" != /www/server/panel/vhost/nginx/tcp/* ]] || continue
    fi
    if nginx_tcp443_file_has_active "$candidate"; then
      printf '%s\0' "$candidate" >>"$manifest"
    fi
  done < <(nginx_config_candidates)
}

nginx_tcp443_rewrite_file() {
  local file="$1" internal_port="$2" tmp output
  tmp="$(mktemp "$(dirname "$file")/.etxr-nginx.XXXXXX")"
  output="$(mktemp "$(dirname "$file")/.etxr-nginx-output.XXXXXX")"
  if ! awk -v port="$internal_port" '
    {
      line = $0
      lower = tolower(line)
      if (lower ~ /^[ \t]*#/ || lower ~ /^[ \t]*$/) {
        print line
        next
      }
      if (lower ~ /^[ \t]*listen[ \t]+(0\.0\.0\.0:)?443([ \t;]|$)/ &&
          lower !~ /(^|[ \t])quic([ \t;]|$)/) {
        sub(/listen[ \t]+(0\.0\.0\.0:)?443/, "listen 127.0.0.1:" port, line)
        print line " # etxr-tcp443: was public 443"
        next
      }
      print line
    }
  ' "$file" >"$output"; then
    rm -f "$tmp" "$output"
    return 2
  fi
  if cmp -s "$file" "$output"; then
    rm -f "$tmp" "$output"
    return 1
  fi
  rm -f "$tmp"
  cp -a -- "$file" "$tmp" || {
    rm -f "$tmp" "$output"
    return 2
  }
  cat "$output" >"$tmp" || {
    rm -f "$tmp" "$output"
    return 2
  }
  rm -f "$output"
  mv -f -- "$tmp" "$file"
}

nginx_tcp443_rebind_manifest() {
  local manifest="$1" backup="$2" internal_port="$3" file rc
  NGINX_TCP443_CHANGED=0
  mkdir -p "$backup"
  : >"$backup/manifest"
  while IFS= read -r -d '' file; do
    nginx_quic_backup_file "$file" "$backup"
    if nginx_tcp443_rewrite_file "$file" "$internal_port"; then
      NGINX_TCP443_CHANGED=1
    else
      rc=$?
      (( rc == 1 )) || return "$rc"
    fi
  done <"$manifest"
}

nginx_tcp443_restore_backup() {
  nginx_quic_restore_backup "$1"
}

nginx_process_running() {
  if command -v pgrep >/dev/null 2>&1 && pgrep -x nginx >/dev/null 2>&1; then
    return 0
  fi
  port_is_nginx_owned tcp 443 || port_is_nginx_owned udp 443
}

confirm_hy2_udp443_share() {
  local manifest file occupied_by_other=0
  printf '\n%s网站 TCP 443 与 Hysteria2 UDP 443 同时使用：%s\n' "$C_BOLD" "$C_RESET"
  printf '  • 网站、XHTTP、Reality 继续使用 TCP 443\n'
  printf '  • Hysteria2 单独使用 UDP 443，两者不会争用同一个协议端口\n'

  if port_is_listening udp 443 &&
     ! port_is_nginx_owned udp 443 &&
     ! port_is_sing_box_owned udp 443; then
    occupied_by_other=1
  fi
  if (( occupied_by_other )); then
    warn "UDP 443 已被 nginx/sing-box 以外的程序占用，暂时不能共用"
    return 1
  fi

  manifest="$(mktemp)"
  nginx_quic_active_manifest "$manifest"
  if [[ -s "$manifest" ]] || port_is_nginx_owned udp 443; then
    printf '\n%s检测到 nginx 已启用 QUIC/HTTP3，占用了 UDP 443。%s\n' \
      "$C_YELLOW" "$C_RESET"
    printf '继续后脚本会自动：\n'
    printf '  1. 备份命中的 nginx 配置\n'
    printf '  2. 关闭 listen 443 quic、HTTP/3 和 Alt-Svc H3 公告\n'
    printf '  3. 保留普通 HTTPS、HTTP/2 和 TCP 443\n'
    printf '  4. 测试 nginx；失败时自动恢复全部文件\n'
    while IFS= read -r -d '' file; do
      printf '     - %s\n' "$file"
    done <"$manifest"
    if ! menu_confirm "确认自动关闭 nginx H3/QUIC 并让 Hysteria2 使用 UDP 443"; then
      rm -f "$manifest"
      return 1
    fi
  fi
  rm -f "$manifest"
  return 0
}

verify_hy2_udp_listener() {
  local port="$1" shared="$2" attempt
  command -v ss >/dev/null 2>&1 || {
    warn "没有 ss 命令，跳过 Hysteria2 UDP 监听验证"
    return 0
  }
  for ((attempt=1; attempt<=20; attempt++)); do
    if port_is_listening udp "$port"; then
      if [[ "$shared" == "true" ]] && port_is_nginx_owned udp "$port"; then
        warn "UDP $port 仍由 nginx 占用"
        return 1
      fi
      if port_is_sing_box_owned udp "$port"; then
        return 0
      fi
    fi
    sleep 0.25
  done
  warn "Hysteria2 未在 UDP $port 上成功监听"
  return 1
}

prompt_port_checked() {
  local label="$1" default="$2" proto="$3" value
  while true; do
    value="$(prompt_value "$label" "$default")"
    if ! valid_port "$value"; then
      warn "端口必须是 1 到 65535 的数字"
      continue
    fi
    if port_is_listening "$proto" "$value"; then
      warn "$proto 端口 $value 已被占用，请换一个端口"
      continue
    fi
    printf '%s' "$value"
    return
  done
}

prompt_port_value() {
  local label="$1" default="$2" value
  while true; do
    value="$(prompt_value "$label" "$default")"
    if valid_port "$value"; then
      printf '%s' "$value"
      return
    fi
    warn "端口必须是 1 到 65535 的数字"
  done
}

prompt_mbps() {
  local label="$1" default="$2" value
  while true; do
    value="$(prompt_value "$label" "$default")"
    if valid_mbps "$value"; then
      printf '%s' "$value"
      return
    fi
    warn "带宽必须是 0 到 100000 的整数，0 表示不限速"
  done
}

prompt_name_value() {
  local label="$1" default="$2" value
  while true; do
    value="$(prompt_value "$label" "$default")"
    if valid_name "$value"; then
      printf '%s' "$value"
      return
    fi
    warn "名称只能包含字母、数字、点、下划线和短横线，最长 64 位"
  done
}

prompt_hostname_value() {
  local label="$1" default="$2" value
  while true; do
    value="$(prompt_value "$label" "$default")"
    if valid_hostname "$value"; then
      printf '%s' "$value"
      return
    fi
    warn "IP 或域名格式不正确"
  done
}

prompt_ipv4_value() {
  local label="$1" default="$2" value
  while true; do
    value="$(prompt_value "$label" "$default")"
    if valid_ipv4 "$value"; then
      printf '%s' "$value"
      return
    fi
    warn "IPv4 地址格式不正确"
  done
}

prompt_target_value() {
  local label="$1" default="$2" value host port
  while true; do
    value="$(prompt_value "$label" "$default")"
    host="${value%:*}"
    port="${value##*:}"
    if [[ "$host" != "$value" ]] && valid_hostname "$host" && valid_port "$port"; then
      printf '%s' "$value"
      return
    fi
    warn "目标格式应为 域名:端口，例如 www.microsoft.com:443"
  done
}

prompt_uuid_value() {
  local label="$1" default="$2" value
  while true; do
    value="$(prompt_value "$label" "$default")"
    if valid_uuid "$value"; then
      printf '%s' "${value,,}"
      return
    fi
    warn "UUID 格式不正确"
  done
}

prompt_path_value() {
  local label="$1" default="$2" value
  while true; do
    value="$(normalize_path "$(prompt_value "$label" "$default")")"
    if valid_http_path "$value" && [[ "$value" != "/" ]]; then
      printf '%s' "$value"
      return
    fi
    warn "Path 必须以 / 开头，且不能使用根路径 /"
  done
}

prompt_url_value() {
  local label="$1" default="$2" value
  while true; do
    value="$(prompt_value "$label" "$default")"
    if valid_url "$value"; then
      printf '%s' "$value"
      return
    fi
    warn "请输入完整的 http:// 或 https:// 网址"
  done
}

menu_confirm() {
  local label="$1" answer
  read -r -p "${label} [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
need_jq() { need_cmd jq; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "This command must run as root"; }

run() {
  if (( DRY_RUN )); then
    printf '+ ' >&2
    printf '%q ' "$@" >&2
    printf '\n' >&2
  else
    "$@"
  fi
}

confirm() {
  local prompt="$1" reply
  (( YES )) && return 0
  read -r -p "${prompt} [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

require_state() {
  [[ -f "$STATE_FILE" ]] || die "State not found: $STATE_FILE (run init first)"
  need_jq
  jq -e '.schema_version == 1' "$STATE_FILE" >/dev/null ||
    die "Unsupported or invalid state: $STATE_FILE"
}

ensure_parent() { mkdir -p "$(dirname "$1")"; }

atomic_write() {
  local target="$1" tmp
  ensure_parent "$target"
  tmp="$(mktemp "$(dirname "$target")/.etxr.XXXXXX")"
  cat >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$target"
}

state_update() {
  local filter="$1"; shift
  local tmp
  require_state
  state_lock_acquire
  tmp="$(mktemp "$(dirname "$STATE_FILE")/.state.XXXXXX")"
  jq "$@" "$filter" "$STATE_FILE" >"$tmp" || {
    rm -f "$tmp"
    die "Failed to update state"
  }
  jq -e . "$tmp" >/dev/null || {
    rm -f "$tmp"
    die "Updated state is invalid JSON"
  }
  mv -f "$tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
  state_lock_release
}

state_lock_acquire() {
  if (( STATE_LOCK_HELD )); then
    STATE_LOCK_DEPTH="$((STATE_LOCK_DEPTH + 1))"
    return 0
  fi
  need_cmd flock
  ensure_parent "$STATE_FILE"
  exec 9>"${STATE_FILE}.lock"
  flock -x 9
  STATE_LOCK_HELD=1
  STATE_LOCK_DEPTH=1
}

state_lock_release() {
  (( STATE_LOCK_HELD )) || return 0
  if (( STATE_LOCK_DEPTH > 1 )); then
    STATE_LOCK_DEPTH="$((STATE_LOCK_DEPTH - 1))"
    return 0
  fi
  flock -u 9 || true
  exec 9>&-
  STATE_LOCK_HELD=0
  STATE_LOCK_DEPTH=0
}

random_hex() {
  local bytes="${1:-16}"
  openssl rand -hex "$bytes"
}

random_path() {
  local bytes="${1:-12}"
  printf '/%s' "$(random_hex "$bytes")"
}

random_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import uuid; print(uuid.uuid4())'
  else
    die "uuidgen, /proc random UUID, or python3 is required"
  fi
}

random_password() {
  openssl rand -base64 24 | tr -d '\n=/+' | cut -c1-28
}

sha1_prefix() {
  local value="$1"
  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$value" | sha1sum | awk '{print substr($1, 1, 8)}'
  else
    printf '%s' "$value" | openssl dgst -sha1 -r | awk '{print substr($1, 1, 8)}'
  fi
}

ensure_control_state() {
  require_state
  local role base_path
  role="$(jq -r '.node.role' "$STATE_FILE")"
  [[ "$role" != "exit" ]] || return 0
  base_path="$(jq -r '.control.base_path // ""' "$STATE_FILE")"
  base_path="${base_path:-$(random_path 16)}"
  state_update '
    .control = ((.control // {}) + {
      enabled: true,
      base_path: $base_path,
      listen: "127.0.0.1",
      port: $port
    })
  ' --arg base_path "$base_path" --argjson port "$CONTROL_PORT"
}

control_base_url() {
  printf 'https://%s%s' \
    "$(jq -r '.node.domain' "$STATE_FILE")" \
    "$(jq -r '.control.base_path' "$STATE_FILE")"
}

render_control_desired() {
  require_state
  [[ "$(jq -r '.control.enabled // false' "$STATE_FILE")" == "true" ]] ||
    return 0
  local node name token base version output issued_at
  mkdir -p "$CONTROL_DIR/nodes" "$CONTROL_DIR/reports"
  chmod 700 "$CONTROL_DIR" "$CONTROL_DIR/nodes" "$CONTROL_DIR/reports"
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    name="$(jq -r '.name' <<<"$node")"
    token="$(jq -r '.control_token // ""' <<<"$node")"
    [[ -n "$token" ]] || continue
    base="$(jq -c --arg node "$name" '{
      node_id: $node,
      users: .users,
      domain_audit: {
        enabled: (.domain_audit.enabled // false),
        retention_days: (.domain_audit.retention_days // 30),
        max_domains_per_user: (.domain_audit.max_domains_per_user // 500)
      }
    }' "$STATE_FILE")"
    version="$(printf '%s' "$base" | sha256sum | awk '{print $1}')"
    issued_at="$(date +%s)"
    output="$(jq -n -c \
      --arg node "$name" --arg version "$version" \
      --arg generated "$(date -u +%FT%TZ)" \
      --argjson issued_at "$issued_at" \
      --argjson users "$(jq '.users' "$STATE_FILE")" \
      --argjson domain_audit "$(jq '{
        enabled: (.domain_audit.enabled // false),
        retention_days: (.domain_audit.retention_days // 30),
        max_domains_per_user: (.domain_audit.max_domains_per_user // 500)
      }' "$STATE_FILE")" '
      {
        node_id: $node,
        version: $version,
        issued_at: $issued_at,
        generated_at: $generated,
        users: $users,
        domain_audit: $domain_audit
      }
    ')"
    printf '%s\n' "$output" | atomic_write "$CONTROL_DIR/nodes/${name}.json"
  done < <(jq -c '(.paired_nodes // [])[]' "$STATE_FILE")
}

normalize_path() {
  local value="$1"
  [[ "$value" == /* ]] || value="/$value"
  value="${value%/}"
  [[ -n "$value" ]] || value="/"
  printf '%s' "$value"
}

valid_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 )); }
valid_ipv4() {
  local value="$1" octet
  local -a octets
  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<<"$value"
  for octet in "${octets[@]}"; do
    (( 10#$octet <= 255 )) || return 1
  done
}
valid_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]
}
valid_hostname() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}
valid_http_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._~/-]+$ && "$1" != *"//"* && "$1" != *".."* ]]
}
valid_absolute_path() { [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ ]]; }
valid_secret_value() { [[ "$1" =~ ^[A-Za-z0-9._:@+-]{1,256}$ ]]; }
valid_socks_credential() { [[ ${#1} -le 255 && ! "$1" =~ [[:cntrl:]] ]]; }
valid_bearer_token() { [[ "$1" =~ ^[0-9a-fA-F]{40}$ ]]; }
valid_subscription_prefix() { [[ "$1" =~ ^[0-9a-fA-F]{8}$ ]]; }
valid_control_token() { [[ "$1" =~ ^[0-9a-fA-F]{64}$ ]]; }

parse_common_flags() {
  local -a rest=()
  while (($#)); do
    case "$1" in
      --state) [[ $# -ge 2 ]] || die "--state needs a file"; STATE_FILE="$2"; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      --force) FORCE=1; shift ;;
      --yes) YES=1; shift ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  REMAINING_ARGS=("${rest[@]}")
}

cmd_init() {
  local name="" role="" domain="" address="" nginx_mode="standalone"
  local cert="" key="" snippet="" xray_config="/etc/etxr/live/xray.json"
  local sing_config="/etc/etxr/live/sing-box.json"
  local tls_port=443 https_listen_port=8443 stream_path=""
  local stream_loader_path="" shared_tcp443=false auto_rebind_https=false
  local control_path

  if [[ "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage:
  etxr init --name hk --role gateway --domain hk.example.com \
    --address hk.example.com --nginx-mode standalone \
    --cert /etc/letsencrypt/live/hk.example.com/fullchain.pem \
    --key /etc/letsencrypt/live/hk.example.com/privkey.pem

Baota extension mode:
  etxr init --name us --role exit --domain us.example.com \
    --nginx-mode snippet \
    --snippet /www/server/panel/vhost/nginx/extension/us.example.com/etxr.conf \
    --cert /www/server/panel/vhost/cert/us.example.com/fullchain.pem \
    --key /www/server/panel/vhost/cert/us.example.com/privkey.pem

Shared Baota TCP 443:
  add --nginx-shared-tcp443 true --nginx-https-listen-port 8443
  Reality public port is 443 and its local listen port is separate.
EOF
    return
  fi

  while (($#)); do
    case "$1" in
      --name) name="$2"; shift 2 ;;
      --role) role="$2"; shift 2 ;;
      --domain) domain="$2"; shift 2 ;;
      --address) address="$2"; shift 2 ;;
      --nginx-mode) nginx_mode="$2"; shift 2 ;;
      --cert) cert="$2"; shift 2 ;;
      --key) key="$2"; shift 2 ;;
      --snippet) snippet="$2"; shift 2 ;;
      --tls-port) tls_port="$2"; shift 2 ;;
      --nginx-https-listen-port) https_listen_port="$2"; shift 2 ;;
      --nginx-stream-path) stream_path="$2"; shift 2 ;;
      --nginx-stream-loader-path) stream_loader_path="$2"; shift 2 ;;
      --nginx-shared-tcp443) shared_tcp443="$2"; shift 2 ;;
      --nginx-auto-rebind-https) auto_rebind_https="$2"; shift 2 ;;
      --xray-config) xray_config="$2"; shift 2 ;;
      --sing-box-config) sing_config="$2"; shift 2 ;;
      *) die "Unknown init option: $1" ;;
    esac
  done

  [[ -n "$name" && -n "$role" && -n "$domain" ]] ||
    die "init requires --name, --role, and --domain"
  valid_name "$name" || die "Invalid node name"
  valid_hostname "$domain" || die "Invalid domain"
  [[ "$role" == "gateway" || "$role" == "exit" || "$role" == "hybrid" ]] ||
    die "--role must be gateway, exit, or hybrid"
  [[ "$nginx_mode" == "standalone" || "$nginx_mode" == "snippet" ||
     "$nginx_mode" == "disabled" ]] ||
    die "--nginx-mode must be standalone, snippet, or disabled"
  valid_port "$tls_port" || die "Invalid TLS port"
  valid_port "$https_listen_port" || die "Invalid nginx HTTPS listen port"
  valid_port "$LIMITER_PORT" || die "Invalid limiter port"
  valid_port "$XRAY_API_PORT" || die "Invalid Xray API port"
  valid_port "$HY2_BRIDGE_PORT" || die "Invalid Hysteria2 bridge port"
  [[ "$shared_tcp443" == "true" || "$shared_tcp443" == "false" ]] ||
    die "Invalid nginx shared TCP 443 flag"
  [[ "$auto_rebind_https" == "true" || "$auto_rebind_https" == "false" ]] ||
    die "Invalid nginx auto rebind HTTPS flag"
  if [[ "$shared_tcp443" == "true" ]]; then
    [[ "$nginx_mode" == "snippet" || "$nginx_mode" == "standalone" ]] ||
      die "Shared TCP 443 requires nginx snippet or standalone mode"
    [[ "$tls_port" == "443" ]] ||
      die "Shared TCP 443 requires public TLS port 443"
    [[ "$https_listen_port" != "443" ]] ||
      die "nginx internal HTTPS port must differ from 443"
    if [[ "$nginx_mode" == "snippet" ]]; then
      [[ -n "$stream_path" ]] ||
        stream_path="/www/server/panel/vhost/nginx/tcp/etxr.conf"
    else
      [[ -n "$stream_path" ]] || stream_path="/etc/nginx/stream-conf.d/etxr.conf"
      [[ -n "$stream_loader_path" ]] ||
        stream_loader_path="/etc/nginx/modules-enabled/99-etxr-stream.conf"
      auto_rebind_https=false
    fi
  else
    auto_rebind_https=false
  fi
  [[ -z "$cert" ]] || valid_absolute_path "$cert" || die "Invalid certificate path"
  [[ -z "$key" ]] || valid_absolute_path "$key" || die "Invalid certificate key path"
  [[ -z "$stream_path" ]] || valid_absolute_path "$stream_path" ||
    die "Invalid nginx stream path"
  [[ -z "$stream_loader_path" ]] || valid_absolute_path "$stream_loader_path" ||
    die "Invalid nginx stream loader path"
  valid_absolute_path "$xray_config" || die "Invalid Xray config path"
  valid_absolute_path "$sing_config" || die "Invalid sing-box config path"
  [[ "$nginx_mode" != "snippet" || -n "$snippet" ]] ||
    die "--snippet is required in snippet mode"
  [[ -z "$snippet" ]] || valid_absolute_path "$snippet" || die "Invalid nginx snippet path"
  [[ ! -e "$STATE_FILE" || "$FORCE" -eq 1 ]] ||
    die "State already exists: $STATE_FILE (use --force to replace)"

  address="${address:-$domain}"
  control_path="$(random_path 16)"
  ensure_parent "$STATE_FILE"

  jq -n \
    --arg name "$name" \
    --arg role "$role" \
    --arg domain "$domain" \
    --arg address "$address" \
    --arg mode "$nginx_mode" \
    --arg cert "$cert" \
    --arg key "$key" \
    --arg snippet "$snippet" \
    --arg xray_config "$xray_config" \
    --arg sing_config "$sing_config" \
    --arg control_path "$control_path" \
    --arg stream_path "$stream_path" \
    --arg stream_loader_path "$stream_loader_path" \
    --argjson shared_tcp443 "$shared_tcp443" \
    --argjson auto_rebind_https "$auto_rebind_https" \
    --argjson https_listen_port "$https_listen_port" \
    --argjson tls_port "$tls_port" \
    --argjson limiter_port "$LIMITER_PORT" \
    --argjson xray_api_port "$XRAY_API_PORT" \
    --argjson hy2_bridge_port "$HY2_BRIDGE_PORT" \
    '{
      schema_version: 1,
      node: {
        name: $name,
        role: $role,
        domain: $domain,
        address: $address
      },
      nginx: {
        mode: $mode,
        tls_port: $tls_port,
        shared_tcp443: $shared_tcp443,
        auto_rebind_https: $auto_rebind_https,
        https_listen_port: $https_listen_port,
        stream_path: $stream_path,
        stream_loader_path: $stream_loader_path,
        certificate: $cert,
        certificate_key: $key,
        snippet_path: $snippet,
        standalone_path: "/etc/nginx/conf.d/etxr.conf",
        paths_path: "/etc/etxr/live/nginx-paths.conf",
        web_root: "/var/www/etxr"
      },
      xray: {
        config_path: $xray_config,
        loglevel: "warning",
        block_bittorrent: true,
        routes: [],
        exits: [],
        reality_inbounds: [],
        relay_inbounds: []
      },
      hysteria2: {
        enabled: false,
        config_path: $sing_config,
        listen: "0.0.0.0",
        port: 8443,
        shared_udp443: false,
        up_mbps: 0,
        down_mbps: 0,
        obfs: "salamander",
        obfs_password: "",
        masquerade: "",
        certificate: $cert,
        certificate_key: $key,
        insecure: false
      },
      easytier: {
        enabled: false,
        ipv4: "",
        public_endpoint: "",
        network_name: "",
        network_secret: "",
        peer: "",
        tcp_port: 11010
      },
      paired_nodes: [],
      control: {
        enabled: ($role != "exit"),
        base_path: $control_path,
        listen: "127.0.0.1",
        port: 18180,
        agent: {enabled: false}
      },
      data_plane: {
        limiter_listen: "127.0.0.1",
        limiter_port: $limiter_port,
        xray_api_port: $xray_api_port,
        hy2_bridge_port: $hy2_bridge_port
      },
      domain_audit: {
        enabled: false,
        retention_days: 30,
        max_domains_per_user: 500
      },
      subscription: {
        enabled: ($role != "exit"),
        base_path: ""
      },
      users: []
    }' | atomic_write "$STATE_FILE"

  log "Initialized $STATE_FILE"
  log "Next: add at least one user and one route"
}

enabled_nodes_json() {
  local value="$1" json node
  if [[ "$value" == "*" ]]; then
    printf '["*"]'
    return
  fi
  json="$(printf '%s' "$value" | jq -R '
    split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) |
    map(select(length > 0)) | unique
  ')"
  while IFS= read -r node; do
    valid_node_key "$node" || die "无效的节点标识：$node"
  done < <(jq -r '.[]' <<<"$json")
  printf '%s' "$json"
}

enabled_nodes_need_hy2() {
  local nodes_json="$1"
  jq -e 'any(.[]; endswith("/hy2"))' <<<"$nodes_json" >/dev/null && return 0
  jq -e 'index("*") != null' <<<"$nodes_json" >/dev/null || return 1
  available_nodes_json | jq -s -e 'any(.[]; .protocol == "hy2")' >/dev/null
}

cmd_user_add() {
  local name="" uuid="" password="" expires="" routes="*" nodes=""
  local routes_set=0 nodes_set=0 sub_token sub_prefix
  local up_mbps=0 down_mbps=0 usage_epoch domain_epoch
  while (($#)); do
    case "$1" in
      --name) name="$2"; shift 2 ;;
      --uuid) uuid="$2"; shift 2 ;;
      --password) password="$2"; shift 2 ;;
      --expires) expires="$2"; shift 2 ;;
      --routes) routes="$2"; routes_set=1; shift 2 ;;
      --nodes) nodes="$2"; nodes_set=1; shift 2 ;;
      --up-mbps) up_mbps="$2"; shift 2 ;;
      --down-mbps) down_mbps="$2"; shift 2 ;;
      --help)
        cat <<'EOF'
Usage: etxr user add --name alice [--uuid UUID] [--password PASS]
       [--expires 2027-01-01T00:00:00Z]
       [--nodes '*|hk/xhttp/hk,tw/reality/direct']
       [--routes '*|hk,tw,us']
       [--up-mbps 0] [--down-mbps 0]
EOF
        return ;;
      *) die "未知的新增用户参数：$1" ;;
    esac
  done
  require_state
  [[ -n "$name" ]] || die "必须填写 --name"
  valid_name "$name" || die "用户名格式不正确"
  jq -e --arg name "$name" '.users[]? | select(.name == $name)' "$STATE_FILE" >/dev/null &&
    die "用户已存在：$name"
  uuid="${uuid:-$(random_uuid)}"
  usage_epoch="$(random_hex 8)"
  domain_epoch="$(random_hex 8)"
  valid_uuid "$uuid" || die "UUID 格式不正确"
  valid_mbps "$up_mbps" || die "上传限速格式不正确"
  valid_mbps "$down_mbps" || die "下载限速格式不正确"
  if [[ -n "$expires" ]]; then
    [[ "$expires" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
      die "到期时间必须使用 UTC ISO-8601 格式，例如 2027-01-01T00:00:00Z"
    date -u -d "$expires" +%s >/dev/null 2>&1 ||
      die "到期时间无效"
  fi
  sub_token="$(random_hex 20)"
  sub_prefix="$(sha1_prefix "$name")"

  local routes_json nodes_json node_name
  node_name="$(jq -r '.node.name' "$STATE_FILE")"
  if (( nodes_set )); then
    nodes_json="$(enabled_nodes_json "$nodes")"
  elif (( routes_set )) && [[ "$routes" != "*" ]]; then
    nodes_json="$(printf '%s' "$routes" | jq -R --arg node "$node_name" '
      split(",") | map(select(length > 0)) |
      map($node + "/xhttp/" + .) | unique
    ')"
  else
    nodes_json='["*"]'
  fi
  jq -e 'length > 0' <<<"$nodes_json" >/dev/null ||
    die "新增用户至少要选择一个可用节点"
  if enabled_nodes_need_hy2 "$nodes_json" && [[ -z "$password" ]]; then
    password="$(random_password)"
  fi
  jq -e 'type == "string" and length <= 512 and
    (test("[\u0000-\u001f\u007f]") | not)' <<<"$(jq -Rn --arg v "$password" '$v')" >/dev/null ||
    die "Hysteria2 密码格式不正确"

  if jq -e 'index("*") != null' <<<"$nodes_json" >/dev/null; then
    routes_json='["*"]'
  else
    routes_json="$(jq '[.[] | select(contains("/xhttp/")) | split("/")[-1]] | unique' \
      <<<"$nodes_json")"
  fi
  state_update \
    '.users += [{
      name: $name,
      uuid: $uuid,
      hy2_password: $password,
      enabled: true,
      expires_at: (if $expires == "" then null else $expires end),
      routes: $routes,
      enabled_nodes: $enabled_nodes,
      subscription_prefix: $prefix,
      subscription_token: $token,
      speed_limit: {
        up_mbps: $up_mbps,
        down_mbps: $down_mbps
      },
      usage_epoch: $usage_epoch,
      domain_epoch: $domain_epoch
    }]' \
    --arg name "$name" --arg uuid "$uuid" --arg password "$password" \
    --arg expires "$expires" --arg prefix "$sub_prefix" \
    --arg token "$sub_token" --arg usage_epoch "$usage_epoch" \
    --arg domain_epoch "$domain_epoch" \
    --argjson routes "$routes_json" --argjson up_mbps "$up_mbps" \
    --argjson enabled_nodes "$nodes_json" --argjson down_mbps "$down_mbps"
  log "已添加用户：$name"
  printf 'UUID：%s\n' "$uuid"
  [[ -z "$password" ]] || printf 'Hysteria2 密码：%s\n' "$password"
  printf '订阅路径：/%s/%s\n' "$sub_prefix" "$sub_token"
}

cmd_user_remove() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "用法：etxr user remove 用户名"
  require_state
  jq -e --arg name "$name" '.users[]? | select(.name == $name)' "$STATE_FILE" >/dev/null ||
    die "用户不存在：$name"
  state_update '.users |= map(select(.name != $name))' --arg name "$name"
  log "已删除用户：$name"
}

cmd_user_list() {
  require_state
  jq -r '
    ["用户名","状态","上传限速","下载限速","到期时间","可用节点"],
    (.users[] | [
      .name,
      (if .enabled then "已启用" else "已暂停" end),
      (if (.speed_limit.up_mbps // 0) == 0 then "不限速" else "\(.speed_limit.up_mbps) Mbps" end),
      (if (.speed_limit.down_mbps // 0) == 0 then "不限速" else "\(.speed_limit.down_mbps) Mbps" end),
      (.expires_at // "-"),
      (if ((.enabled_nodes // ["*"]) | index("*")) != null then "全部节点"
       else "\((.enabled_nodes // []) | length) 个节点" end)
    ])
    | @tsv' "$STATE_FILE" | column -t -s $'\t' 2>/dev/null ||
    jq -r '.users[] |
      "用户名=\(.name)\t状态=\(if .enabled then "已启用" else "已暂停" end)\t上传=\(.speed_limit.up_mbps // 0)Mbps\t下载=\(.speed_limit.down_mbps // 0)Mbps\t到期=\(.expires_at // "-")\t节点=\(if ((.enabled_nodes // ["*"]) | index("*")) != null then "全部" else ((.enabled_nodes // []) | length | tostring) end)"' "$STATE_FILE"
}

cmd_user_nodes() {
  local name="${1:-}" nodes="" password="" nodes_json routes_json current_password
  [[ -n "$name" ]] || die "用法：etxr user nodes 用户名 --nodes 节点列表"
  shift || true
  while (($#)); do
    case "$1" in
      --nodes) nodes="$2"; shift 2 ;;
      --password) password="$2"; shift 2 ;;
      *) die "未知的用户节点参数：$1" ;;
    esac
  done
  require_state
  jq -e --arg name "$name" '.users[]? | select(.name == $name)' \
    "$STATE_FILE" >/dev/null || die "用户不存在：$name"
  nodes_json="$(enabled_nodes_json "$nodes")"
  current_password="$(jq -r --arg name "$name" \
    '.users[] | select(.name == $name) | (.hy2_password // "")' "$STATE_FILE")"
  if enabled_nodes_need_hy2 "$nodes_json" &&
     [[ -z "$password" && -z "$current_password" ]]; then
    password="$(random_password)"
    printf '已为该用户生成 Hysteria2 密码：%s\n' "$password"
  fi
  [[ -n "$password" ]] || password="$current_password"
  jq -e 'type == "string" and length <= 512 and
    (test("[\u0000-\u001f\u007f]") | not)' <<<"$(jq -Rn --arg v "$password" '$v')" >/dev/null ||
    die "Hysteria2 密码格式不正确"
  if jq -e 'index("*") != null' <<<"$nodes_json" >/dev/null; then
    routes_json='["*"]'
  else
    routes_json="$(jq '[.[] | select(contains("/xhttp/")) | split("/")[-1]] | unique' \
      <<<"$nodes_json")"
  fi
  state_update '
    (.users[] | select(.name == $name)) |= (
      .enabled_nodes = $nodes |
      .routes = $routes |
      .hy2_password = $password
    )
  ' --arg name "$name" --arg password "$password" \
    --argjson nodes "$nodes_json" --argjson routes "$routes_json"
  log "已更新用户 ${name} 的可用节点"
}

ensure_hy2_passwords_for_node() {
  local node_name="$1" node_key user_name password
  node_key="${node_name}/hy2"
  while IFS= read -r user_name; do
    [[ -n "$user_name" ]] || continue
    password="$(random_password)"
    state_update '
      (.users[] | select(.name == $name) | .hy2_password) = $password
    ' --arg name "$user_name" --arg password "$password"
  done < <(jq -r --arg key "$node_key" '
    .users[] |
    select(
      (.hy2_password // "") == "" and
      ((.enabled_nodes // ["*"]) as $nodes |
       (($nodes | index("*")) != null or ($nodes | index($key)) != null))
    ) |
    .name
  ' "$STATE_FILE")
}

cmd_user_limit() {
  local name="${1:-}" up_mbps="" down_mbps=""
  [[ -n "$name" ]] || die "用法：etxr user limit 用户名 --up-mbps N --down-mbps N"
  shift || true
  while (($#)); do
    case "$1" in
      --up-mbps) up_mbps="$2"; shift 2 ;;
      --down-mbps) down_mbps="$2"; shift 2 ;;
      *) die "未知的用户限速参数：$1" ;;
    esac
  done
  require_state
  jq -e --arg name "$name" '.users[]? | select(.name == $name)' \
    "$STATE_FILE" >/dev/null || die "用户不存在：$name"
  [[ -n "$up_mbps" ]] ||
    up_mbps="$(jq -r --arg name "$name" \
      '.users[] | select(.name == $name) | (.speed_limit.up_mbps // 0)' "$STATE_FILE")"
  [[ -n "$down_mbps" ]] ||
    down_mbps="$(jq -r --arg name "$name" \
      '.users[] | select(.name == $name) | (.speed_limit.down_mbps // 0)' "$STATE_FILE")"
  valid_mbps "$up_mbps" || die "Invalid upload Mbps"
  valid_mbps "$down_mbps" || die "Invalid download Mbps"
  state_update '
    (.users[] | select(.name == $name)) |= (
      .speed_limit = {up_mbps: $up_mbps, down_mbps: $down_mbps} |
      .usage_epoch = (.usage_epoch // $usage_epoch)
    )
  ' --arg name "$name" --arg usage_epoch "$(random_hex 8)" \
    --argjson up_mbps "$up_mbps" --argjson down_mbps "$down_mbps"
  log "Updated speed limit for $name: upload=${up_mbps}Mbps download=${down_mbps}Mbps"
}

cmd_user_reset_usage() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "用法：etxr user reset-usage 用户名|all"
  require_state
  if [[ "$name" == "all" ]]; then
    state_update '.users |= map(.usage_epoch = $epoch)' \
      --arg epoch "$(random_hex 8)"
  else
    jq -e --arg name "$name" '.users[]? | select(.name == $name)' \
      "$STATE_FILE" >/dev/null || die "用户不存在：$name"
    state_update '(.users[] | select(.name == $name) | .usage_epoch) = $epoch' \
      --arg name "$name" --arg epoch "$(random_hex 8)"
  fi
  log "Usage reset requested for $name"
}

cmd_user_reset_domains() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "用法：etxr user reset-domains 用户名|all"
  require_state
  if [[ "$name" == "all" ]]; then
    state_update '.users |= map(.domain_epoch = $epoch)' \
      --arg epoch "$(random_hex 8)"
  else
    jq -e --arg name "$name" '.users[]? | select(.name == $name)' \
      "$STATE_FILE" >/dev/null || die "用户不存在：$name"
    state_update '(.users[] | select(.name == $name) | .domain_epoch) = $epoch' \
      --arg name "$name" --arg epoch "$(random_hex 8)"
  fi
  log "已请求清空 ${name} 的访问域名历史"
}

format_bytes() {
  local value="${1:-0}"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec-i --suffix=B "$value"
  else
    printf '%s B' "$value"
  fi
}

cmd_user_usage() {
  local name="${1:-}" sources totals line
  require_state
  if [[ -n "$name" ]]; then
    jq -e --arg name "$name" '.users[]? | select(.name == $name)' \
      "$STATE_FILE" >/dev/null || die "用户不存在：$name"
  fi
  if [[ -x "$DATAPLANE_BIN" && -x "$XRAY_BIN" && ${EUID:-$(id -u)} -eq 0 ]]; then
    "$DATAPLANE_BIN" meter --state "$STATE_FILE" \
      --usage-file "$USAGE_FILE" --xray-bin "$XRAY_BIN" --once \
      >/dev/null 2>&1 || true
  fi
  sources="$(mktemp)"
  if [[ -f "$USAGE_FILE" ]]; then
    jq -c '{updated_at: (.updated_at // 0), users: (.users // {})}' \
      "$USAGE_FILE" >>"$sources" 2>/dev/null || true
  fi
  if [[ "$(jq -r '.node.role' "$STATE_FILE")" != "exit" &&
        -d "$CONTROL_DIR/reports" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && printf '%s\n' "$line" >>"$sources"
    done < <(jq -c '
      select(.usage | type == "object") |
      {
        updated_at: (.usage.updated_at // 0),
        users: (.usage.users // {})
      }
    ' "$CONTROL_DIR"/reports/*.json 2>/dev/null || true)
  fi
  totals="$(jq -s --slurpfile state "$STATE_FILE" '
    $state[0].users as $configured |
    reduce .[] as $source (
      {};
      reduce (($source.users // {}) | to_entries[]) as $entry (
        .;
        ($configured | map(select(
          .name == $entry.key and
          .uuid == ($entry.value.uuid // "") and
          ((.usage_epoch // "") | tostring) ==
            (($entry.value.usage_epoch // "") | tostring)
        )) | first // null) as $known |
        if $known == null then .
        else
          .[$entry.key].uplink =
            ((.[$entry.key].uplink // 0) + ($entry.value.uplink // 0)) |
          .[$entry.key].downlink =
            ((.[$entry.key].downlink // 0) + ($entry.value.downlink // 0))
        end
      )
    )
  ' "$sources")"
  rm -f "$sources"

  printf '用户\t上传\t下载\t合计\t上传限速\t下载限速\n'
  while IFS=$'\t' read -r user_name uplink downlink up_limit down_limit; do
    [[ -n "$user_name" ]] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$user_name" \
      "$(format_bytes "$uplink")" \
      "$(format_bytes "$downlink")" \
      "$(format_bytes "$((uplink + downlink))")" \
      "$([[ "$up_limit" == "0" ]] && printf '不限速' || printf '%s Mbps' "$up_limit")" \
      "$([[ "$down_limit" == "0" ]] && printf '不限速' || printf '%s Mbps' "$down_limit")"
  done < <(jq -r --arg name "$name" --argjson totals "$totals" '
    .users[] |
    select($name == "" or .name == $name) |
    [
      .name,
      ($totals[.name].uplink // 0),
      ($totals[.name].downlink // 0),
      (.speed_limit.up_mbps // 0),
      (.speed_limit.down_mbps // 0)
    ] | @tsv
  ' "$STATE_FILE")
}

collect_domain_sources() {
  local output="$1" report
  : >"$output"
  if [[ -f "$DOMAIN_FILE" ]] && jq -e '
    .schema == 1 and (.users | type == "object")
  ' "$DOMAIN_FILE" >/dev/null 2>&1; then
    jq -c '.' "$DOMAIN_FILE" >>"$output"
  fi
  if [[ "$(jq -r '.node.role' "$STATE_FILE")" != "exit" &&
        -d "$CONTROL_DIR/reports" ]]; then
    while IFS= read -r -d '' report; do
      jq -c 'select(.domains | type == "object") | .domains' \
        "$report" >>"$output" 2>/dev/null || true
    done < <(find "$CONTROL_DIR/reports" -maxdepth 1 -type f -name '*.json' -print0)
  fi
}

cmd_user_domains() {
  local name="${1:-}" limit="${2:-50}" sources entries unresolved enabled
  require_state
  [[ -z "$name" ]] || jq -e --arg name "$name" \
    '.users[]? | select(.name == $name)' "$STATE_FILE" >/dev/null ||
    die "用户不存在：$name"
  if [[ ! "$limit" =~ ^[0-9]+$ ]] || (( limit < 1 || limit > 5000 )); then
    die "显示数量必须是 1 到 5000"
  fi
  enabled="$(jq -r '.domain_audit.enabled // false' "$STATE_FILE")"
  printf '域名统计：%s（保留 %s 天，每用户最多 %s 个域名）\n' \
    "$([[ "$enabled" == "true" ]] && printf '已启用' || printf '未启用')" \
    "$(jq -r '.domain_audit.retention_days // 30' "$STATE_FILE")" \
    "$(jq -r '.domain_audit.max_domains_per_user // 500' "$STATE_FILE")"
  sources="$(mktemp)"
  collect_domain_sources "$sources"
  entries="$(jq -s --slurpfile state "$STATE_FILE" --arg name "$name" \
    --argjson limit "$limit" '
    $state[0].users as $configured |
    [
      .[] as $source |
      (if (($source.node // "") | type == "string" and
          test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"))
       then $source.node else "-" end) as $node |
      (($source.users // {}) | to_entries[]) as $user |
      $configured[] |
      select(
        .name == $user.key and
        .uuid == ($user.value.uuid // "") and
        ((.domain_epoch // "") == ($user.value.domain_epoch // "")) and
        ($name == "" or .name == $name)
      ) as $identity |
      (($user.value.domains // {}) | to_entries[]) |
      select(
        (.key | type == "string" and
          test("^[A-Za-z0-9._-]{1,253}$")) and
        (.value.connections | type == "number") and
        (.value.last_seen | type == "number")
      ) |
      {
        user: $identity.name,
        domain: .key,
        connections: .value.connections,
        first_seen: (.value.first_seen // .value.last_seen),
        last_seen: .value.last_seen,
        node: $node
      }
    ] |
    group_by([.user, .domain]) |
    map({
      user: .[0].user,
      domain: .[0].domain,
      connections: (map(.connections) | add),
      first_seen: (map(.first_seen) | min),
      last_seen: (map(.last_seen) | max),
      nodes: (map(.node) | unique | join(","))
    }) |
    sort_by(.user, (-.last_seen), (-.connections), .domain) |
    group_by(.user) | map(.[0:$limit]) | flatten
  ' "$sources")"
  if [[ "$(jq 'length' <<<"$entries")" == "0" ]]; then
    printf '暂无可识别的域名记录。启用后产生新连接才会开始统计。\n'
  else
    jq -r '
      ["用户","域名","连接次数","首次访问(UTC)","最近访问(UTC)","记录节点"],
      (.[] | [
        .user, .domain, (.connections | tostring),
        (.first_seen | todateiso8601), (.last_seen | todateiso8601), .nodes
      ]) | @tsv
    ' <<<"$entries" | column -t -s $'\t' 2>/dev/null ||
      jq -r '.[] | "用户=\(.user) 域名=\(.domain) 次数=\(.connections) 最近=\(.last_seen | todateiso8601) 节点=\(.nodes)"' \
        <<<"$entries"
  fi
  unresolved="$(jq -s --slurpfile state "$STATE_FILE" --arg name "$name" '
    $state[0].users as $configured |
    [
      .[] as $source |
      (($source.users // {}) | to_entries[]) as $user |
      $configured[] |
      select(
        .name == $user.key and
        .uuid == ($user.value.uuid // "") and
        ((.domain_epoch // "") == ($user.value.domain_epoch // "")) and
        ($name == "" or .name == $name)
      ) |
      {user: .name, count: ($user.value.unresolved // 0)} |
      select(.count > 0)
    ] |
    group_by(.user) |
    map({user: .[0].user, count: (map(.count) | add)})
  ' "$sources")"
  rm -f "$sources"
  if [[ "$(jq 'length' <<<"$unresolved")" != "0" ]]; then
    printf '\n无法识别域名的连接（IP-only、ECH 或非 HTTP/TLS/QUIC）：\n'
    jq -r '.[] | "  \(.user)：\(.count) 次"' <<<"$unresolved"
  fi
}

cmd_domain() {
  local action="${1:-show}" retention="" maximum=""
  shift || true
  require_state
  case "$action" in
    enable)
      state_update '.domain_audit = ((.domain_audit // {}) + {enabled: true,
        retention_days: (.domain_audit.retention_days // 30),
        max_domains_per_user: (.domain_audit.max_domains_per_user // 500)})'
      log "已启用用户访问域名统计"
      ;;
    disable)
      state_update '.domain_audit = ((.domain_audit // {}) + {enabled: false,
        retention_days: (.domain_audit.retention_days // 30),
        max_domains_per_user: (.domain_audit.max_domains_per_user // 500)})'
      log "已停止记录新的访问域名；已有历史仍保留"
      ;;
    configure)
      while (($#)); do
        case "$1" in
          --retention-days) retention="$2"; shift 2 ;;
          --max-domains) maximum="$2"; shift 2 ;;
          *) die "未知的域名统计参数：$1" ;;
        esac
      done
      retention="${retention:-$(jq -r '.domain_audit.retention_days // 30' "$STATE_FILE")}"
      maximum="${maximum:-$(jq -r '.domain_audit.max_domains_per_user // 500' "$STATE_FILE")}"
      if [[ ! "$retention" =~ ^[0-9]+$ ]] ||
         (( retention < 1 || retention > 365 )); then
        die "保留天数必须是 1 到 365"
      fi
      if [[ ! "$maximum" =~ ^[0-9]+$ ]] ||
         (( maximum < 10 || maximum > 5000 )); then
        die "每用户域名上限必须是 10 到 5000"
      fi
      state_update '.domain_audit = ((.domain_audit // {}) + {
        enabled: (.domain_audit.enabled // false),
        retention_days: $retention,
        max_domains_per_user: $maximum
      })' --argjson retention "$retention" --argjson maximum "$maximum"
      log "域名统计设置已更新：保留 ${retention} 天，每用户最多 ${maximum} 个"
      ;;
    show)
      jq -r --arg file "$DOMAIN_FILE" '
        "状态：\(if (.domain_audit.enabled // false) then "已启用" else "未启用" end)\n" +
        "保留天数：\(.domain_audit.retention_days // 30)\n" +
        "每用户域名上限：\(.domain_audit.max_domains_per_user // 500)\n" +
        "本机数据文件：\($file)"
      ' "$STATE_FILE"
      if command -v systemctl >/dev/null 2>&1; then
        printf '本机服务：%s\n' \
          "$(systemctl is-active etxr-domain-audit.service 2>/dev/null || true)"
      fi
      ;;
    *) die "用法：etxr domain enable|disable|show|configure" ;;
  esac
}

cmd_user() {
  local action="${1:-}"; shift || true
  case "$action" in
    add) cmd_user_add "$@" ;;
    remove|rm) cmd_user_remove "$@" ;;
    list|ls) cmd_user_list ;;
    limit) cmd_user_limit "$@" ;;
    usage) cmd_user_usage "$@" ;;
    reset-usage) cmd_user_reset_usage "$@" ;;
    domains) cmd_user_domains "$@" ;;
    reset-domains) cmd_user_reset_domains "$@" ;;
    nodes) cmd_user_nodes "$@" ;;
    enable|disable)
      local name="${1:-}"; [[ -n "$name" ]] || die "必须填写用户名"
      jq -e --arg name "$name" '.users[]? | select(.name == $name)' "$STATE_FILE" >/dev/null ||
        die "用户不存在：$name"
      local enabled=true; [[ "$action" == "disable" ]] && enabled=false
      state_update '(.users[] | select(.name == $name) | .enabled) = $enabled' \
        --arg name "$name" --argjson enabled "$enabled"
      ;;
    *) die "用法：etxr user add|remove|list|enable|disable|nodes|limit|usage|reset-usage|domains|reset-domains" ;;
  esac
}

cmd_route_add() {
  local name="" path="" port="" target="direct" profile="plain"
  local decryption="none" encryption="none" flow="" host=""
  while (($#)); do
    case "$1" in
      --name) name="$2"; shift 2 ;;
      --path) path="$2"; shift 2 ;;
      --port) port="$2"; shift 2 ;;
      --target) target="$2"; shift 2 ;;
      --profile) profile="$2"; shift 2 ;;
      --decryption) decryption="$2"; shift 2 ;;
      --client-encryption) encryption="$2"; shift 2 ;;
      --flow) flow="$2"; shift 2 ;;
      --host) host="$2"; shift 2 ;;
      --help)
        cat <<'EOF'
Usage:
  etxr route add --name hk --path /PATH_HK --port 18001 --target direct
  etxr route add --name tw --path /PATH_TW --port 18002 --target tw

VLESS Encryption + Vision + XHTTP XMUX + nginx TLS:
  etxr keys vlessenc
  etxr route add --name pq --path /PATH_PQ --port 18003 \
    --profile vlessenc-vision \
    --decryption 'SERVER_DECRYPTION' \
    --client-encryption 'CLIENT_ENCRYPTION'

Profiles:
  plain               VLESS + XHTTP behind nginx TLS
  vlessenc-vision     VLESS Encryption + Vision + XHTTP/XMUX behind nginx TLS
EOF
        return ;;
      *) die "Unknown route add option: $1" ;;
    esac
  done
  require_state
  [[ -n "$name" && -n "$path" && -n "$port" ]] ||
    die "route add requires --name, --path, and --port"
  valid_name "$name" || die "Invalid route name"
  valid_port "$port" || die "Invalid port"
  path="$(normalize_path "$path")"
  valid_http_path "$path" || die "Path may contain only letters, digits, /, ., _, ~, and -"
  [[ "$path" != "/" ]] || die "Root path / is not allowed"
  [[ -z "$host" ]] || valid_hostname "$host" || die "Invalid HTTP host"
  [[ "$profile" == "plain" || "$profile" == "vlessenc-vision" ]] ||
    die "Unsupported route profile: $profile"
  if [[ "$profile" == "vlessenc-vision" ]]; then
    [[ "$decryption" != "none" && "$encryption" != "none" ]] ||
      die "vlessenc-vision needs --decryption and --client-encryption"
    flow="${flow:-xtls-rprx-vision}"
  else
    decryption="none"
    encryption="none"
    flow=""
  fi
  if [[ "$target" != "direct" ]]; then
    jq -e --arg name "$target" '.xray.exits[]? | select(.name == $name)' "$STATE_FILE" >/dev/null ||
      die "Target exit does not exist: $target (add it first)"
  fi
  jq -e --arg name "$name" '.xray.routes[]? | select(.name == $name)' "$STATE_FILE" >/dev/null &&
    die "Route already exists: $name"
  jq -e --arg path "$path" '.xray.routes[]? | select(.path == $path)' "$STATE_FILE" >/dev/null &&
    die "Path already exists: $path"
  jq -e --argjson port "$port" '.xray.routes[]? | select(.port == $port)' "$STATE_FILE" >/dev/null &&
    die "Route port already exists: $port"

  state_update \
    '.xray.routes += [{
      name: $name, path: $path, listen: "127.0.0.1", port: $port,
      target: $target, profile: $profile, host: $host,
      decryption: $decryption, client_encryption: $encryption, flow: $flow
    }]' \
    --arg name "$name" --arg path "$path" --arg target "$target" \
    --arg profile "$profile" --arg host "$host" \
    --arg decryption "$decryption" --arg encryption "$encryption" --arg flow "$flow" \
    --argjson port "$port"
  log "Added path route $path -> $target via local port $port"
}

cmd_route_remove() {
  local name="${1:-}"; [[ -n "$name" ]] || die "Route name required"
  state_update '.xray.routes |= map(select(.name != $name))' --arg name "$name"
}

cmd_route_list() {
  require_state
  jq -r '.xray.routes[]? |
    "\(.name)\t\(.path)\t127.0.0.1:\(.port)\ttarget=\(.target)\tprofile=\(.profile)"' "$STATE_FILE"
}

cmd_route() {
  local action="${1:-}"; shift || true
  case "$action" in
    add) cmd_route_add "$@" ;;
    remove|rm) cmd_route_remove "$@" ;;
    list|ls) cmd_route_list ;;
    *) die "Usage: etxr route add|remove|list" ;;
  esac
}

cmd_exit_add() {
  local name="" address="" port=443 transport="tls" server_name="" host="" path=""
  local uuid="" encryption="none" flow="" public_key="" short_id="" fingerprint="chrome"
  local socks_username="" socks_password=""
  while (($#)); do
    case "$1" in
      --name) name="$2"; shift 2 ;;
      --address) address="$2"; shift 2 ;;
      --port) port="$2"; shift 2 ;;
      --transport) transport="$2"; shift 2 ;;
      --server-name) server_name="$2"; shift 2 ;;
      --host) host="$2"; shift 2 ;;
      --path) path="$2"; shift 2 ;;
      --uuid) uuid="$2"; shift 2 ;;
      --encryption) encryption="$2"; shift 2 ;;
      --flow) flow="$2"; shift 2 ;;
      --public-key) public_key="$2"; shift 2 ;;
      --short-id) short_id="$2"; shift 2 ;;
      --fingerprint) fingerprint="$2"; shift 2 ;;
      --username) socks_username="$2"; shift 2 ;;
      --password) socks_password="$2"; shift 2 ;;
      --help)
        cat <<'EOF'
Usage:
  etxr exit add --name tw --address tw.example.com --port 443 \
    --transport tls --server-name tw.example.com --host tw.example.com \
    --path /RELAY_PATH --uuid UUID

  etxr exit add --name us --address US_IP --port 8444 \
    --transport reality --server-name REALITY_SNI --path /RELAY_PATH \
    --uuid UUID --public-key PUBLIC_KEY --short-id SHORT_ID

  etxr exit add --name tw-private --address 10.10.0.2 --port 18000 \
    --transport none --path /RELAY_PATH --uuid UUID \
    --encryption CLIENT_VLESS_ENCRYPTION --flow xtls-rprx-vision

  etxr exit add --name socks-tw --address 127.0.0.1 --port 1080 \
    --transport socks5 [--username USER --password PASS]

transport: tls | reality | none | socks5
For transport=none, use a private overlay address or VLESS Encryption.
EOF
        return ;;
      *) die "Unknown exit add option: $1" ;;
    esac
  done
  require_state
  [[ -n "$name" && -n "$address" ]] ||
    die "exit add requires --name and --address"
  valid_name "$name" || die "Invalid exit name"
  valid_port "$port" || die "Invalid port"
  [[ "$address" =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid exit address"
  [[ "$transport" == "tls" || "$transport" == "reality" ||
     "$transport" == "none" || "$transport" == "socks5" ]] ||
    die "--transport must be tls, reality, none, or socks5"
  if [[ "$transport" == "socks5" ]]; then
    valid_socks_credential "$socks_username" || die "Invalid SOCKS5 username"
    valid_socks_credential "$socks_password" || die "Invalid SOCKS5 password"
    [[ ( -z "$socks_username" && -z "$socks_password" ) ||
       ( -n "$socks_username" && -n "$socks_password" ) ]] ||
      die "SOCKS5 username and password must be provided together"
    path=""
    uuid=""
    server_name=""
    host=""
    encryption="none"
    flow=""
    public_key=""
    short_id=""
  else
    [[ -n "$path" && -n "$uuid" ]] ||
      die "VLESS exit requires --path and --uuid"
    valid_uuid "$uuid" || die "Invalid UUID"
    path="$(normalize_path "$path")"
    valid_http_path "$path" || die "Path may contain only letters, digits, /, ., _, ~, and -"
    [[ "$path" != "/" ]] || die "Root path / is not allowed"
    server_name="${server_name:-$address}"
    host="${host:-$server_name}"
    valid_hostname "$server_name" || die "Invalid server name"
    valid_hostname "$host" || die "Invalid HTTP host"
    if [[ "$transport" == "reality" ]]; then
      [[ -n "$public_key" && -n "$short_id" ]] ||
        die "Reality exit needs --public-key and --short-id"
    fi
    if [[ "$transport" == "none" && "$encryption" == "none" ]]; then
      warn "Unencrypted VLESS is only suitable for a trusted private overlay"
    fi
  fi
  jq -e --arg name "$name" '.xray.exits[]? | select(.name == $name)' "$STATE_FILE" >/dev/null &&
    die "Exit already exists: $name"

  state_update \
    '.xray.exits += [{
      name: $name, address: $address, port: $port, transport: $transport,
      server_name: $server_name, host: $host, path: $path, uuid: $uuid,
      encryption: $encryption, flow: $flow, public_key: $public_key,
      short_id: $short_id, fingerprint: $fingerprint,
      socks_username: $socks_username, socks_password: $socks_password,
      xmux: {
        maxConcurrency: "16-32", maxConnections: 0,
        cMaxReuseTimes: "64-128", cMaxLifetimeMs: 0,
        hMaxRequestTimes: "800-900", hKeepAlivePeriod: 0
      }
    }]' \
    --arg name "$name" --arg address "$address" --arg transport "$transport" \
    --arg server_name "$server_name" --arg host "$host" --arg path "$path" \
    --arg uuid "$uuid" --arg encryption "$encryption" --arg flow "$flow" \
    --arg public_key "$public_key" --arg short_id "$short_id" \
    --arg socks_username "$socks_username" --arg socks_password "$socks_password" \
    --arg fingerprint "$fingerprint" --argjson port "$port"
  log "Added exit $name"
}

cmd_exit_remove() {
  local name="${1:-}"; [[ -n "$name" ]] || die "Exit name required"
  require_state
  jq -e --arg name "$name" '.xray.routes[]? | select(.target == $name)' "$STATE_FILE" >/dev/null &&
    die "Exit $name is still used by a route"
  state_update '.xray.exits |= map(select(.name != $name))' --arg name "$name"
}

cmd_exit_list() {
  require_state
  jq -r '.xray.exits[]? |
    if .transport == "socks5" then
      "\(.name)\tsocks5://\(.address):\(.port)\tauth=" +
      (if (.socks_username // "") == "" then "no" else "yes" end)
    else
      "\(.name)\t\(.transport)://\(.address):\(.port)\tpath=\(.path)\tflow=\(.flow // "")"
    end' "$STATE_FILE"
}

cmd_exit() {
  local action="${1:-}"; shift || true
  case "$action" in
    add) cmd_exit_add "$@" ;;
    remove|rm) cmd_exit_remove "$@" ;;
    list|ls) cmd_exit_list ;;
    *) die "Usage: etxr exit add|remove|list" ;;
  esac
}

cmd_reality_add() {
  local name="" port="" listen_port="" listen_address="0.0.0.0"
  local path="" target="" server_names="" private_key="" public_key="" short_ids=""
  while (($#)); do
    case "$1" in
      --name) name="$2"; shift 2 ;;
      --port) port="$2"; shift 2 ;;
      --listen-port) listen_port="$2"; shift 2 ;;
      --listen-address) listen_address="$2"; shift 2 ;;
      --path) path="$2"; shift 2 ;;
      --target) target="$2"; shift 2 ;;
      --server-names) server_names="$2"; shift 2 ;;
      --private-key) private_key="$2"; shift 2 ;;
      --public-key) public_key="$2"; shift 2 ;;
      --short-ids) short_ids="$2"; shift 2 ;;
      --help)
        cat <<'EOF'
Usage:
  etxr keys reality
  etxr reality add --name reality --port 8444 --path /REALITY_PATH \
    --target TARGET_DOMAIN:443 --server-names SNI1,SNI2 \
    --listen-port 8444 --listen-address 0.0.0.0 \
    --private-key PRIVATE_KEY --public-key PUBLIC_KEY \
    --short-ids SHORT_ID1,SHORT_ID2
EOF
        return ;;
      *) die "Unknown reality add option: $1" ;;
    esac
  done
  require_state
  [[ -n "$name" && -n "$port" && -n "$path" && -n "$target" &&
     -n "$server_names" && -n "$private_key" && -n "$public_key" &&
     -n "$short_ids" ]] ||
    die "Missing required Reality option"
  valid_name "$name" || die "Invalid Reality name"
  valid_port "$port" || die "Invalid Reality port"
  if [[ "$(jq -r '.nginx.shared_tcp443 // false' "$STATE_FILE")" == "true" ]]; then
    [[ "$port" == "443" ]] ||
      die "Shared TCP 443 Reality must use public port 443"
    listen_address="127.0.0.1"
    listen_port="${listen_port:-18443}"
  fi
  listen_port="${listen_port:-$port}"
  valid_port "$listen_port" || die "Invalid Reality listen port"
  [[ "$listen_address" == "0.0.0.0" || "$listen_address" == "127.0.0.1" ]] ||
    die "Invalid Reality listen address"
  path="$(normalize_path "$path")"
  valid_http_path "$path" || die "Path may contain only letters, digits, /, ., _, ~, and -"
  [[ "$path" != "/" ]] || die "Root path / is not allowed"
  [[ "$target" =~ ^[A-Za-z0-9.-]+:[0-9]{1,5}$ ]] || die "Invalid Reality target"
  valid_hostname "${server_names%%,*}" || die "Invalid Reality server name"
  [[ "$private_key" =~ ^[A-Za-z0-9_-]{20,256}$ ]] || die "Invalid Reality private key"
  [[ "$public_key" =~ ^[A-Za-z0-9_-]{20,256}$ ]] || die "Invalid Reality public key"
  local server_names_json short_ids_json
  server_names_json="$(printf '%s' "$server_names" | jq -R 'split(",") | map(select(length > 0))')"
  short_ids_json="$(printf '%s' "$short_ids" | jq -R 'split(",") | map(select(length > 0))')"
  state_update \
    '.xray.reality_inbounds += [{
      name: $name, listen: $listen_address, port: $port, listen_port: $listen_port,
      path: $path,
      target: $target, server_names: $server_names,
      private_key: $private_key, public_key: $public_key, short_ids: $short_ids
    }]' \
    --arg name "$name" --arg path "$path" --arg target "$target" \
    --arg listen_address "$listen_address" \
    --arg private_key "$private_key" --arg public_key "$public_key" \
    --argjson port "$port" --argjson listen_port "$listen_port" \
    --argjson server_names "$server_names_json" \
    --argjson short_ids "$short_ids_json"
}

cmd_reality_remove() {
  local name="${1:-}"; [[ -n "$name" ]] || die "Reality name required"
  state_update '.xray.reality_inbounds |= map(select(.name != $name))' --arg name "$name"
}

cmd_reality_list() {
  require_state
  jq -r '.xray.reality_inbounds[]? |
    "\(.name)\tpublic=\(.port)\tlisten=\(.listen // "0.0.0.0"):\(.listen_port // .port)\tpath=\(.path)\tSNI=\(.server_names|join(","))"' "$STATE_FILE"
}

cmd_reality() {
  local action="${1:-}"; shift || true
  case "$action" in
    add) cmd_reality_add "$@" ;;
    remove|rm) cmd_reality_remove "$@" ;;
    list|ls) cmd_reality_list ;;
    *) die "Usage: etxr reality add|remove|list" ;;
  esac
}

cmd_hy2_enable() {
  local port=8443 up=0 down=0 obfs="salamander" obfs_password="" masquerade=""
  local cert="" key="" shared_udp443=false share_flag_seen=0
  while (($#)); do
    case "$1" in
      --port) port="$2"; shift 2 ;;
      --share-udp443) shared_udp443=true; share_flag_seen=1; shift ;;
      --no-share-udp443) shared_udp443=false; share_flag_seen=1; shift ;;
      --up-mbps) up="$2"; shift 2 ;;
      --down-mbps) down="$2"; shift 2 ;;
      --obfs) obfs="$2"; shift 2 ;;
      --obfs-password) obfs_password="$2"; shift 2 ;;
      --masquerade) masquerade="$2"; shift 2 ;;
      --cert) cert="$2"; shift 2 ;;
      --key) key="$2"; shift 2 ;;
      --help)
        cat <<'EOF'
Usage:
  etxr hy2 enable --port 443 --share-udp443 \
    --up-mbps 30 --down-mbps 200 \
    --obfs salamander --masquerade https://www.example.com

--share-udp443 means Hysteria2 uses UDP 443 while HTTPS keeps TCP 443.
During apply, ETXR backs up and disables nginx QUIC/HTTP3 automatically.
EOF
        return ;;
      *) die "Unknown hy2 option: $1" ;;
    esac
  done
  require_state
  valid_port "$port" || die "Invalid Hysteria2 port"
  [[ "$shared_udp443" == "true" || "$shared_udp443" == "false" ]] ||
    die "Invalid Hysteria2 UDP 443 sharing flag"
  if [[ "$shared_udp443" == "true" && "$port" != "443" ]]; then
    die "--share-udp443 requires --port 443"
  fi
  if [[ "$port" == "443" && "$share_flag_seen" -eq 0 ]]; then
    shared_udp443=false
  fi
  if [[ "$port" == "443" && "$shared_udp443" == "false" ]] &&
     { port_is_nginx_owned udp 443 || nginx_quic_has_active; }; then
    die "nginx H3/QUIC 正在使用 UDP 443；请添加 --share-udp443 让 ETXR 自动备份并关闭它"
  fi
  [[ "$obfs" == "salamander" || "$obfs" == "none" ]] ||
    die "--obfs must be salamander or none"
  valid_mbps "$up" || die "Invalid upload Mbps"
  valid_mbps "$down" || die "Invalid download Mbps"
  [[ -z "$masquerade" ]] || valid_url "$masquerade" || die "Invalid Hysteria2 masquerade URL"
  if [[ "$obfs" == "salamander" ]]; then
    obfs_password="${obfs_password:-$(random_password)}"
  else
    obfs_password=""
  fi
  cert="${cert:-$(jq -r '.nginx.certificate' "$STATE_FILE")}"
  key="${key:-$(jq -r '.nginx.certificate_key' "$STATE_FILE")}"
  state_update \
    '.hysteria2.enabled = true |
     .hysteria2.port = $port |
     .hysteria2.shared_udp443 = $shared_udp443 |
     .hysteria2.up_mbps = $up |
     .hysteria2.down_mbps = $down |
     .hysteria2.obfs = $obfs |
     .hysteria2.obfs_password = $password |
     .hysteria2.masquerade = $masquerade |
     .hysteria2.certificate = $cert |
     .hysteria2.certificate_key = $key' \
    --argjson port "$port" --argjson shared_udp443 "$shared_udp443" \
    --argjson up "$up" --argjson down "$down" \
    --arg obfs "$obfs" --arg password "$obfs_password" \
    --arg masquerade "$masquerade" --arg cert "$cert" --arg key "$key"
  ensure_hy2_passwords_for_node "$(jq -r '.node.name' "$STATE_FILE")"
  log "Enabled Hysteria2 on UDP $port (shared UDP 443: $shared_udp443)"
  [[ -z "$obfs_password" ]] || printf 'Hysteria2 obfs password: %s\n' "$obfs_password"
}

cmd_hy2() {
  local action="${1:-}"; shift || true
  case "$action" in
    enable) cmd_hy2_enable "$@" ;;
    disable)
      state_update '
        .hysteria2.enabled = false |
        .hysteria2.shared_udp443 = false
      '
      ;;
    show) require_state; jq '.hysteria2' "$STATE_FILE" ;;
    *) die "Usage: etxr hy2 enable|disable|show" ;;
  esac
}

cmd_keys() {
  local kind="${1:-}"
  case "$kind" in
    reality)
      [[ -x "$XRAY_BIN" ]] || die "Xray not found at $XRAY_BIN"
      "$XRAY_BIN" x25519
      printf 'ShortId: %s\n' "$(random_hex 8)"
      ;;
    vlessenc)
      [[ -x "$XRAY_BIN" ]] || die "Xray not found at $XRAY_BIN"
      "$XRAY_BIN" vlessenc
      ;;
    *) die "Usage: etxr keys reality|vlessenc" ;;
  esac
}

render_xray() {
  local out="$1" tmp_users tmp_routes tmp_exits tmp_reality tmp_relays
  local tmp_output block loglevel domain_audit_enabled
  ensure_parent "$out"
  tmp_users="$(mktemp)"
  tmp_routes="$(mktemp)"
  tmp_exits="$(mktemp)"
  tmp_reality="$(mktemp)"
  tmp_relays="$(mktemp)"
  tmp_output="$(mktemp "$(dirname "$out")/.xray.XXXXXX")"
  jq --argjson now_epoch "$(date +%s)" '
    [.users[] | select(
      .enabled == true and
      (.expires_at == null or .expires_at == "" or
       (((.expires_at | fromdateiso8601?) // 0) > $now_epoch))
    )]' "$STATE_FILE" >"$tmp_users"
  jq '.xray.routes' "$STATE_FILE" >"$tmp_routes"
  jq '.xray.exits' "$STATE_FILE" >"$tmp_exits"
  jq '.xray.reality_inbounds' "$STATE_FILE" >"$tmp_reality"
  jq '.xray.relay_inbounds // []' "$STATE_FILE" >"$tmp_relays"
  block="$(jq -r '.xray.block_bittorrent' "$STATE_FILE")"
  loglevel="$(jq -r '.xray.loglevel' "$STATE_FILE")"
  domain_audit_enabled="$(jq -r '.domain_audit.enabled // false' "$STATE_FILE")"

  jq -n \
    --slurpfile users "$tmp_users" \
    --slurpfile routes "$tmp_routes" \
    --slurpfile exits "$tmp_exits" \
    --slurpfile realities "$tmp_reality" \
    --slurpfile relays "$tmp_relays" \
    --arg node_name "$(jq -r '.node.name' "$STATE_FILE")" \
    --arg loglevel "$loglevel" \
    --arg domain_webhook "${DOMAIN_SOCKET}:/event" \
    --argjson limiter_port "$(jq -r '.data_plane.limiter_port // 18181' "$STATE_FILE")" \
    --argjson api_port "$(jq -r '.data_plane.xray_api_port // 18182' "$STATE_FILE")" \
    --argjson hy2_bridge_port "$(jq -r '.data_plane.hy2_bridge_port // 18183' "$STATE_FILE")" \
    --argjson hy2_enabled "$(jq -r '.hysteria2.enabled // false' "$STATE_FILE")" \
    --argjson domain_audit_enabled "$domain_audit_enabled" \
    --argjson block "$block" '
    def node_allowed($user; $protocol; $entry_name):
      ($user.enabled_nodes // ["*"]) as $nodes |
      ($node_name + "/" + $protocol +
        (if $protocol == "hy2" then "" else ("/" + $entry_name) end)) as $key |
      (($nodes | index("*")) != null or ($nodes | index($key)) != null);

    def allowed_users($protocol; $entry_name; $flow):
      $users[0]
      | map(select(node_allowed(.; $protocol; $entry_name)))
      | map({
          id: .uuid,
          level: 0,
          email: (.name + "@" + $entry_name)
        } + (if $flow == "" then {} else {flow: $flow} end));

    def sniffing:
      {
        enabled: true,
        destOverride: ["http", "tls", "quic"],
        metadataOnly: false,
        routeOnly: true
      };

    def xhttp_extra_server:
      {
        noSSEHeader: false,
        scMaxEachPostBytes: 1000000,
        scMaxBufferedPosts: 30,
        xPaddingBytes: "100-1000"
      };

    def audit_webhook:
      if $domain_audit_enabled then
        {webhook: {url: $domain_webhook, deduplication: 0}}
      else {} end;

    def limited_users:
      $users[0] | map(select(
        ((.speed_limit.up_mbps // 0) > 0) or
        ((.speed_limit.down_mbps // 0) > 0)
      ));

    def outbound_for_exit($e; $tag; $address; $port; $dialer):
      if ($e.transport // "none") == "socks5" then
        {
          tag: $tag,
          protocol: "socks",
          settings: {
            servers: [
              {
                address: $address,
                port: $port
              }
              + (if ($e.socks_username // "") == "" then {}
                else {
                  users: [{
                    user: $e.socks_username,
                    pass: ($e.socks_password // "")
                  }]
                } end)
            ]
          },
          streamSettings: {
            sockopt: ({
              tcpFastOpen: true,
              tcpNoDelay: true
            } + (if $dialer == "" then {} else {dialerProxy: $dialer} end))
          }
        }
      else
        {
          tag: $tag,
          protocol: "vless",
          settings: {
            vnext: [{
              address: $address,
              port: $port,
              users: [{
                id: $e.uuid,
                encryption: ($e.encryption // "none"),
                level: 0
              } + (if ($e.flow // "") == "" then {} else {flow: $e.flow} end)]
            }]
          },
          streamSettings:
            ({
              network: ($e.network // "xhttp"),
              security: ($e.transport // "none"),
              sockopt: ({
                tcpFastOpen: true,
                tcpNoDelay: true
              } + (if $dialer == "" then {} else {dialerProxy: $dialer} end))
            }
            + (if ($e.network // "xhttp") == "xhttp" then {
                xhttpSettings: {
                  host: ($e.host // ""),
                  path: $e.path,
                  mode: "auto",
                  extra: {
                    noGRPCHeader: false,
                    scMaxEachPostBytes: 1000000,
                    scMinPostsIntervalMs: 30,
                    xPaddingBytes: "100-1000",
                    xmux: ($e.xmux // {})
                  }
                }
              } else {} end)
            + (if ($e.transport // "none") == "tls" then {
                tlsSettings: {
                  serverName: $e.server_name,
                  allowInsecure: false,
                  alpn: ["h2"],
                  fingerprint: ($e.fingerprint // "chrome")
                }
              } elif ($e.transport // "none") == "reality" then {
                realitySettings: {
                  show: false,
                  serverName: $e.server_name,
                  fingerprint: ($e.fingerprint // "chrome"),
                  publicKey: $e.public_key,
                  shortId: $e.short_id,
                  spiderX: "/"
                }
              } else {} end))
        }
      end;

    def exit_outbounds:
      $exits[0] | map(
        . as $e |
        if (($e.backup_address // "") != "") then [
          outbound_for_exit($e; ("exit-" + $e.name + "-primary"); $e.address; $e.port; ""),
          outbound_for_exit($e; ("exit-" + $e.name + "-backup"); $e.backup_address; $e.backup_port; "")
        ] else [
          outbound_for_exit($e; ("exit-" + $e.name); $e.address; $e.port; "")
        ] end
      ) | flatten;

    def limiter_socks_outbounds:
      limited_users | map(. as $u | {
        tag: ("limit-socks-" + $u.name),
        protocol: "socks",
        settings: {
          servers: [{
            address: "127.0.0.1",
            port: $limiter_port,
            users: [{
              user: $u.name,
              pass: $u.subscription_token
            }]
          }]
        }
      });

    def limited_direct_outbounds:
      limited_users | map(. as $u | {
        tag: ("limit-direct-" + $u.name),
        protocol: "freedom",
        settings: {},
        streamSettings: {
          sockopt: {
            dialerProxy: ("limit-socks-" + $u.name)
          }
        }
      });

    def limited_exit_outbounds:
      [
        limited_users[] as $u |
        $exits[0][] as $e |
        if (($e.backup_address // "") != "") then [
          outbound_for_exit(
            $e;
            ("limit-exit-" + $u.name + "-" + $e.name + "-primary");
            $e.address;
            $e.port;
            ("limit-socks-" + $u.name)
          ),
          outbound_for_exit(
            $e;
            ("limit-exit-" + $u.name + "-" + $e.name + "-backup");
            $e.backup_address;
            $e.backup_port;
            ("limit-socks-" + $u.name)
          )
        ] else [
          outbound_for_exit(
            $e;
            ("limit-exit-" + $u.name + "-" + $e.name);
            $e.address;
            $e.port;
            ("limit-socks-" + $u.name)
          )
        ] end
      ] | flatten;

    def target_rule($r):
      ($exits[0] | map(select(.name == $r.target)) | first // null) as $e |
      {
        type: "field",
        inboundTag: [("path-" + $r.name)]
      }
      + (if $r.target == "direct" then {outboundTag: "direct"}
        elif $e != null and (($e.backup_address // "") != "") then
          {balancerTag: ("failover-" + $r.target)}
        else {outboundTag: ("exit-" + $r.target)} end)
      + audit_webhook;

    def limited_route_rules:
      [
        $routes[0][] as $r |
        limited_users[] as $u |
        select(node_allowed($u; "xhttp"; $r.name)) |
        ($exits[0] | map(select(.name == $r.target)) | first // null) as $e |
        {
          type: "field",
          inboundTag: [("path-" + $r.name)],
          user: [($u.name + "@" + $r.name)]
        }
        + (if $r.target == "direct" then
            {outboundTag: ("limit-direct-" + $u.name)}
          elif $e != null and (($e.backup_address // "") != "") then
            {balancerTag: ("limit-failover-" + $u.name + "-" + $r.target)}
          else
            {outboundTag: ("limit-exit-" + $u.name + "-" + $r.target)}
          end)
        + audit_webhook
      ];

    def limited_reality_rules:
      [
        $realities[0][] as $r |
        limited_users[] as $u |
        select(node_allowed($u; "reality"; $r.name)) |
        {
          type: "field",
          inboundTag: [("reality-" + $r.name)],
          user: [($u.name + "@" + $r.name)],
          outboundTag: ("limit-direct-" + $u.name)
        } + audit_webhook
      ];

    def limited_hy2_rules:
      if $hy2_enabled then [
        limited_users[] as $u |
        select(node_allowed($u; "hy2"; "")) |
        {
          type: "field",
          inboundTag: ["hy2-bridge-in"],
          user: [($u.name + "@hy2")],
          outboundTag: ("limit-direct-" + $u.name)
        } + audit_webhook
      ] else [] end;

    def audit_direct_rules:
      if $domain_audit_enabled then
        ($realities[0] | map({
          type: "field",
          inboundTag: [("reality-" + .name)],
          outboundTag: "direct"
        } + audit_webhook))
        +
        (if $hy2_enabled then [{
          type: "field",
          inboundTag: ["hy2-bridge-in"],
          outboundTag: "direct"
        } + audit_webhook] else [] end)
      else [] end;

    {
      log: {loglevel: $loglevel},
      inbounds: (
        ($routes[0] | map(. as $r | {
          tag: ("path-" + $r.name),
          listen: $r.listen,
          port: $r.port,
          protocol: "vless",
          settings: {
            clients: allowed_users("xhttp"; $r.name; ($r.flow // "")),
            decryption: ($r.decryption // "none")
          },
          streamSettings:
            ({
              network: "xhttp",
              security: ($r.security // "none"),
              xhttpSettings: {
                host: ($r.host // ""),
                path: $r.path,
                mode: "auto",
                extra: xhttp_extra_server
              },
              sockopt: {
                acceptProxyProtocol: false,
                tcpFastOpen: true,
                tcpNoDelay: true
              }
            }
            + (if ($r.security // "none") == "tls" then {
                tlsSettings: {
                  certificates: [{
                    certificateFile: $r.certificate,
                    keyFile: $r.certificate_key
                  }]
                }
              } else {} end)),
          sniffing: sniffing
        }))
        +
        ($realities[0] | map(. as $r | {
          tag: ("reality-" + $r.name),
          listen: ($r.listen // "0.0.0.0"),
          port: ($r.listen_port // $r.port),
          protocol: "vless",
          settings: {
            clients: allowed_users("reality"; $r.name; ""),
            decryption: "none"
          },
          streamSettings: {
            network: "xhttp",
            security: "reality",
            realitySettings: {
              show: false,
              target: $r.target,
              xver: 0,
              serverNames: $r.server_names,
              privateKey: $r.private_key,
              shortIds: $r.short_ids
            },
            xhttpSettings: {
              host: "",
              path: $r.path,
              mode: "auto",
              extra: xhttp_extra_server
            },
            sockopt: {
              tcpFastOpen: true,
              tcpNoDelay: true
            }
          },
          sniffing: sniffing
        }))
        +
        ($relays[0] | map(. as $r | {
          tag: ("relay-" + $r.name),
          listen: $r.listen,
          port: $r.port,
          protocol: "vless",
          settings: {
            clients: [{
              id: $r.uuid,
              level: 0,
              email: ("relay@" + $r.name),
              flow: ($r.flow // "xtls-rprx-vision")
            }],
            decryption: $r.decryption
          },
          streamSettings: {
            network: "raw",
            security: "none",
            sockopt: {
              tcpFastOpen: true,
              tcpNoDelay: true
            }
          },
          sniffing: sniffing
        }))
        +
        (if $hy2_enabled then [{
          tag: "hy2-bridge-in",
          listen: "127.0.0.1",
          port: $hy2_bridge_port,
          protocol: "vless",
          settings: {
            clients: ($users[0] | map(select(node_allowed(.; "hy2"; ""))) | map({
              id: .uuid,
              level: 0,
              email: (.name + "@hy2")
            })),
            decryption: "none"
          },
          streamSettings: {
            network: "raw",
            security: "none",
            sockopt: {
              tcpFastOpen: true,
              tcpNoDelay: true
            }
          },
          sniffing: sniffing
        }] else [] end)
        +
        [{
          tag: "api-in",
          listen: "127.0.0.1",
          port: $api_port,
          protocol: "dokodemo-door",
          settings: {address: "127.0.0.1"}
        }]
      ),
      outbounds: (
        [
          {tag: "direct", protocol: "freedom", settings: {}},
          {tag: "blocked", protocol: "blackhole", settings: {}}
        ] + exit_outbounds + limiter_socks_outbounds +
        limited_direct_outbounds + limited_exit_outbounds
      ),
      routing: {
        domainStrategy: "IPIfNonMatch",
        rules: (
          [{
            type: "field",
            inboundTag: ["api-in"],
            outboundTag: "api"
          }]
          +
          (if $block then [{
            type: "field",
            protocol: ["bittorrent"],
            outboundTag: "blocked"
          }] else [] end)
          +
          limited_route_rules
          +
          limited_reality_rules
          +
          limited_hy2_rules
          +
          ($relays[0] | map(
            if (.public // false) and ((.allowed_source // "") != "") then [
              {
                type: "field",
                inboundTag: [("relay-" + .name)],
                source: [.allowed_source],
                outboundTag: "direct"
              },
              {
                type: "field",
                inboundTag: [("relay-" + .name)],
                outboundTag: "blocked"
              }
            ] else [{
              type: "field",
              inboundTag: [("relay-" + .name)],
              outboundTag: "direct"
            }] end
          ) | flatten)
          +
          audit_direct_rules
          +
          ($routes[0] | map(target_rule(.)))
        ),
        balancers:
          (
            ($exits[0] | map(select((.backup_address // "") != "") | {
              tag: ("failover-" + .name),
              selector: [("exit-" + .name + "-primary")],
              fallbackTag: ("exit-" + .name + "-backup"),
              strategy: {type: "leastPing"}
            }))
            +
            ([
              limited_users[] as $u |
              $exits[0][] |
              select((.backup_address // "") != "") |
              {
                tag: ("limit-failover-" + $u.name + "-" + .name),
                selector: [
                  ("limit-exit-" + $u.name + "-" + .name + "-primary")
                ],
                fallbackTag:
                  ("limit-exit-" + $u.name + "-" + .name + "-backup"),
                strategy: {type: "leastPing"}
              }
            ])
          )
      },
      policy: {
        levels: {
          "0": {
            statsUserUplink: true,
            statsUserDownlink: true
          }
        }
      },
      stats: {},
      api: {
        tag: "api",
        services: ["StatsService"]
      }
    }
    + (if ($exits[0] | map(select((.backup_address // "") != "")) | length) > 0 then {
        observatory: {
          subjectSelector: (
            (
              $exits[0] | map(select((.backup_address // "") != "") |
                ("exit-" + .name + "-primary"))
            )
            +
            ([
              limited_users[] as $u |
              $exits[0][] |
              select((.backup_address // "") != "") |
              ("limit-exit-" + $u.name + "-" + .name + "-primary")
            ])
          ),
          probeUrl: "https://connectivitycheck.gstatic.com/generate_204",
          probeInterval: "10s",
          enableConcurrency: true
        }
      } else {} end)
    ' >"$tmp_output" || {
      rm -f "$tmp_users" "$tmp_routes" "$tmp_exits" "$tmp_reality" \
        "$tmp_relays" "$tmp_output"
      die "Xray 配置生成失败；未覆盖现有配置"
    }
  jq -e 'type == "object" and (.inbounds | type == "array")' \
    "$tmp_output" >/dev/null || {
      rm -f "$tmp_users" "$tmp_routes" "$tmp_exits" "$tmp_reality" \
        "$tmp_relays" "$tmp_output"
      die "Xray 配置生成结果不是有效 JSON；未覆盖现有配置"
    }
  chmod 600 "$tmp_output"
  mv -f "$tmp_output" "$out"
  rm -f "$tmp_users" "$tmp_routes" "$tmp_exits" "$tmp_reality" "$tmp_relays"
}

render_nginx_stream() {
  local out="$1" https_port tmp_output idx name listen_port sni
  ensure_parent "$out"
  tmp_output="$(mktemp "$(dirname "$out")/.nginx-stream.XXXXXX")"
  https_port="$(jq -r '.nginx.https_listen_port // 8443' "$STATE_FILE")"

  {
    printf '# Generated by etxr %s. Do not edit.\n' "$VERSION"
    printf '# Requires nginx stream_ssl_preread_module and the Baota tcp include.\n'
    printf 'map $ssl_preread_server_name $etxr_backend {\n'
    printf '    default etxr_https;\n'
    while IFS=$'\t' read -r idx name listen_port; do
      [[ -n "$name" ]] || continue
      while IFS= read -r sni; do
        [[ -n "$sni" ]] || continue
        printf '    %s etxr_reality_%s;\n' "$sni" "$idx"
      done < <(jq -r --arg name "$name" \
        '.xray.reality_inbounds[] | select(.name == $name) | .server_names[]' \
        "$STATE_FILE")
    done < <(jq -r '.xray.reality_inbounds | to_entries[] |
      "\(.key)\t\(.value.name)\t\(.value.listen_port // .value.port)"' "$STATE_FILE")
    printf '}\n\n'
    printf 'upstream etxr_https {\n    server 127.0.0.1:%s;\n}\n\n' "$https_port"
    while IFS=$'\t' read -r idx name listen_port; do
      [[ -n "$name" ]] || continue
      printf 'upstream etxr_reality_%s {\n    server 127.0.0.1:%s;\n}\n\n' \
        "$idx" "$listen_port"
    done < <(jq -r '.xray.reality_inbounds | to_entries[] |
      "\(.key)\t\(.value.name)\t\(.value.listen_port // .value.port)"' "$STATE_FILE")
    cat <<'EOF'
server {
    listen 443;
    proxy_pass $etxr_backend;
    ssl_preread on;
    proxy_connect_timeout 10s;
    proxy_timeout 1h;
}
EOF
  } >"$tmp_output" || {
    rm -f "$tmp_output"
    die "nginx stream 配置生成失败；未覆盖现有配置"
  }
  [[ -s "$tmp_output" ]] || {
    rm -f "$tmp_output"
    die "nginx stream 配置为空；未覆盖现有配置"
  }
  chmod 600 "$tmp_output"
  mv -f "$tmp_output" "$out"
}

render_nginx_paths() {
  local out="$1" domain subdir tmp_output
  ensure_parent "$out"
  tmp_output="$(mktemp "$(dirname "$out")/.nginx-paths.XXXXXX")"
  domain="$(jq -r '.node.domain' "$STATE_FILE")"
  subdir="$SUBSCRIPTION_DIR"
  valid_absolute_path "$subdir" || die "Unsafe subscription directory path"
  while IFS= read -r user; do
    [[ -n "$user" ]] || continue
    valid_subscription_prefix "$(jq -r '.subscription_prefix' <<<"$user")" ||
      die "Invalid subscription prefix in state"
    valid_bearer_token "$(jq -r '.subscription_token' <<<"$user")" ||
      die "Invalid subscription token in state"
  done < <(jq -c '.users[]?' "$STATE_FILE")
  {
    printf '# Generated by etxr %s. Do not edit.\n' "$VERSION"
    jq -r --arg domain "$domain" '
      .xray.routes[] |
      "location ^~ \(.path) {\n" +
      "    proxy_pass http://127.0.0.1:\(.port);\n" +
      "    proxy_http_version 1.1;\n" +
      "    proxy_set_header Host " + (if (.host // "") == "" then $domain else .host end) + ";\n" +
      "    proxy_set_header X-Real-IP $remote_addr;\n" +
      "    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n" +
      "    proxy_set_header X-Forwarded-Proto https;\n" +
      "    proxy_set_header Connection \"\";\n" +
      "    proxy_buffering off;\n" +
      "    proxy_request_buffering off;\n" +
      "    proxy_connect_timeout 15s;\n" +
      "    proxy_send_timeout 600s;\n" +
      "    proxy_read_timeout 600s;\n" +
      "}\n"
    ' "$STATE_FILE"
    jq -r --arg dir "$subdir" '
      . as $root |
      select($root.subscription.enabled == true) |
      $root.users[] |
      "location = /\(.subscription_prefix)/\(.subscription_token) {\n" +
      "    alias \($dir)/\(.subscription_token);\n" +
      "    default_type text/plain;\n" +
      "    add_header Cache-Control \"no-store\";\n" +
      "}\n"
    ' "$STATE_FILE"
    if [[ "$(jq -r '.control.enabled // false' "$STATE_FILE")" == "true" ]]; then
      local control_path control_port
      control_path="$(jq -r '.control.base_path' "$STATE_FILE")"
      control_port="$(jq -r '.control.port' "$STATE_FILE")"
      valid_http_path "$control_path" || die "Invalid control Path"
      valid_port "$control_port" || die "Invalid control port"
      cat <<EOF
location ^~ ${control_path}/ {
    proxy_pass http://127.0.0.1:${control_port}/;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_connect_timeout 15s;
    proxy_send_timeout 60s;
    proxy_read_timeout 3600s;
    client_max_body_size 1m;
}
EOF
    fi
  } >"$tmp_output" || {
    rm -f "$tmp_output"
    die "nginx Path 配置生成失败；未覆盖现有配置"
  }
  [[ -s "$tmp_output" ]] || {
    rm -f "$tmp_output"
    die "nginx Path 配置为空；未覆盖现有配置"
  }
  chmod 600 "$tmp_output"
  mv -f "$tmp_output" "$out"
}

render_nginx_standalone() {
  local out="$1" domain port cert key root include_file redirect_port=""
  local shared_tcp443 https_port listen_address tmp_output
  ensure_parent "$out"
  tmp_output="$(mktemp "$(dirname "$out")/.nginx-standalone.XXXXXX")"
  domain="$(jq -r '.node.domain' "$STATE_FILE")"
  port="$(jq -r '.nginx.tls_port' "$STATE_FILE")"
  cert="$(jq -r '.nginx.certificate' "$STATE_FILE")"
  key="$(jq -r '.nginx.certificate_key' "$STATE_FILE")"
  root="$(jq -r '.nginx.web_root' "$STATE_FILE")"
  include_file="$(jq -r '.nginx.paths_path // "/etc/etxr/live/nginx-paths.conf"' "$STATE_FILE")"
  shared_tcp443="$(jq -r '.nginx.shared_tcp443 // false' "$STATE_FILE")"
  https_port="$(jq -r '.nginx.https_listen_port // 8443' "$STATE_FILE")"
  if [[ "$shared_tcp443" == "true" ]]; then
    listen_address="127.0.0.1:${https_port}"
  else
    listen_address="$port"
  fi
  [[ "$port" == "443" ]] || redirect_port=":${port}"
  cat <<EOF >"$tmp_output"
# Generated by etxr ${VERSION}. Do not edit.
server {
    listen 80;
    server_name ${domain};

    location ^~ /.well-known/acme-challenge/ {
        root ${root};
    }
    location / {
        return 301 https://\$host${redirect_port}\$request_uri;
    }
}

server {
    listen ${listen_address} ssl;
    http2 on;
    server_name ${domain};

    ssl_certificate ${cert};
    ssl_certificate_key ${key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:EDGE_TLS:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=31536000" always;

    include ${include_file};

    location / {
        root ${root};
        try_files \$uri \$uri/ =404;
    }
}
EOF
  [[ -s "$tmp_output" ]] || {
    rm -f "$tmp_output"
    die "nginx 独立站点配置为空；未覆盖现有配置"
  }
  chmod 600 "$tmp_output"
  mv -f "$tmp_output" "$out"
}

render_nginx_stream_loader() {
  local out="$1" stream_dir tmp_output
  ensure_parent "$out"
  stream_dir="$(dirname "$(jq -r '.nginx.stream_path' "$STATE_FILE")")"
  valid_absolute_path "$stream_dir" || die "Invalid nginx stream directory"
  tmp_output="$(mktemp "$(dirname "$out")/.nginx-stream-loader.XXXXXX")"
  cat <<EOF >"$tmp_output"
# Generated by etxr ${VERSION}. Do not edit.
stream {
    include ${stream_dir}/*.conf;
}
EOF
  chmod 600 "$tmp_output"
  mv -f "$tmp_output" "$out"
}

render_sing_box() {
  local out="$1" tmp_output
  ensure_parent "$out"
  tmp_output="$(mktemp "$(dirname "$out")/.sing-box.XXXXXX")"
  jq -n --slurpfile s "$STATE_FILE" '
    $s[0] as $c |
    ($c.node.name + "/hy2") as $hy2_key |
    [
      $c.users[] |
      select(
        .enabled == true and
        (.expires_at == null or .expires_at == "" or
         (((.expires_at | fromdateiso8601?) // 0) > now)) and
        (((.enabled_nodes // ["*"]) | index("*")) != null or
         (((.enabled_nodes // ["*"]) | index($hy2_key)) != null)) and
        ((.hy2_password // "") != "")
      )
    ] as $active_users |
    ($active_users | map({name: .name, password: .hy2_password})) as $users |
    {
      log: {level: "warn", timestamp: true},
      inbounds: [{
        type: "hysteria2",
        tag: "hy2-in",
        listen: $c.hysteria2.listen,
        listen_port: $c.hysteria2.port,
        users: $users,
        tls: {
          enabled: true,
          server_name: $c.node.domain,
          certificate_path: $c.hysteria2.certificate,
          key_path: $c.hysteria2.certificate_key
        },
        masquerade: (
          if $c.hysteria2.masquerade == "" then
            "file:///var/www/etxr"
          else $c.hysteria2.masquerade end
        )
      }
      + (if $c.hysteria2.up_mbps > 0 then {up_mbps: $c.hysteria2.up_mbps} else {} end)
      + (if $c.hysteria2.down_mbps > 0 then {down_mbps: $c.hysteria2.down_mbps} else {} end)
      + (if $c.hysteria2.obfs == "none" then {} else {
          obfs: {
            type: $c.hysteria2.obfs,
            password: $c.hysteria2.obfs_password
          }
        } end)],
      outbounds: (
        [{type: "direct", tag: "direct"}]
        +
        ($active_users | map(. as $u | {
          type: "vless",
          tag: ("hy2-bridge-" + $u.name),
          server: "127.0.0.1",
          server_port: ($c.data_plane.hy2_bridge_port // 18183),
          uuid: $u.uuid,
          packet_encoding: "xudp"
        }))
      ),
      route: {
        rules: (
          (if $c.xray.block_bittorrent then [
              {action: "sniff"},
              {protocol: "bittorrent", action: "reject"}
            ] else [] end)
          +
          ($active_users | map(. as $u | {
            auth_user: [$u.name],
            action: "route",
            outbound: ("hy2-bridge-" + $u.name)
          }))
        ),
        final: "direct",
        auto_detect_interface: true
      }
    }' >"$tmp_output" || {
      rm -f "$tmp_output"
      die "sing-box 配置生成失败；未覆盖现有配置"
    }
  jq -e 'type == "object" and (.inbounds | type == "array")' \
    "$tmp_output" >/dev/null || {
      rm -f "$tmp_output"
      die "sing-box 配置生成结果不是有效 JSON；未覆盖现有配置"
    }
  chmod 600 "$tmp_output"
  mv -f "$tmp_output" "$out"
}

render_limits() {
  local out="$1" tmp_output
  ensure_parent "$out"
  tmp_output="$(mktemp "$(dirname "$out")/.limits.XXXXXX")"
  jq --argjson now_epoch "$(date +%s)" '
    {
      listen: (.data_plane.limiter_listen // "127.0.0.1"),
      port: (.data_plane.limiter_port // 18181),
      users: (
        [.users[] |
          select(
            .enabled == true and
            (.expires_at == null or .expires_at == "" or
             (((.expires_at | fromdateiso8601?) // 0) > $now_epoch)) and
            (
              ((.speed_limit.up_mbps // 0) > 0) or
              ((.speed_limit.down_mbps // 0) > 0)
            )
          ) |
          {
            name: .name,
            password: .subscription_token,
            up_mbps: (.speed_limit.up_mbps // 0),
            down_mbps: (.speed_limit.down_mbps // 0)
          }
        ]
      )
    }
  ' "$STATE_FILE" >"$tmp_output" || {
    rm -f "$tmp_output"
    die "限速配置生成失败；未覆盖现有配置"
  }
  jq -e '
    (.listen == "127.0.0.1") and
    (.port | type == "number" and . >= 1 and . <= 65535) and
    (.users | type == "array")
  ' "$tmp_output" >/dev/null || {
    rm -f "$tmp_output"
    die "限速配置无效；未覆盖现有配置"
  }
  chmod 600 "$tmp_output"
  mv -f "$tmp_output" "$out"
}

urlencode() {
  jq -rn --arg v "$1" '$v | @uri'
}

active_user_json() {
  local name="$1"
  jq -e --arg name "$name" '
    .users[] | select(
      .name == $name and
      .enabled == true and
      (.expires_at == null or .expires_at == "" or
       (((.expires_at | fromdateiso8601?) // 0) > now))
    )' "$STATE_FILE"
}

subscription_entry_from_state() {
  jq -c '{
    schema: 1,
    node: {
      name: .node.name,
      domain: .node.domain,
      address: .node.address
    },
    nginx: {
      tls_port: .nginx.tls_port
    },
    xray: {
      routes: [.xray.routes[]? | {
        name,
        path,
        port,
        public_port: (.public_port // .port),
        target,
        profile,
        host: (.host // ""),
        client_encryption: (.client_encryption // "none"),
        flow: (.flow // ""),
        security: (.security // "tls"),
        direct: (.direct // false),
        allow_insecure: (.allow_insecure // false)
      }],
      reality_inbounds: [.xray.reality_inbounds[]? | {
        name,
        port,
        path,
        server_names,
        public_key: (.public_key // ""),
        short_ids
      }]
    },
    hysteria2: {
      enabled: (.hysteria2.enabled // false),
      port: (.hysteria2.port // 443),
      obfs: (.hysteria2.obfs // "none"),
      obfs_password: (.hysteria2.obfs_password // ""),
      insecure: (.hysteria2.insecure // false)
    }
  }' "$STATE_FILE"
}

validate_worker_subscription_entry() {
  local expected="$1" entry="$2"
  jq -e --arg expected "$expected" '
    def valid_name:
      type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$");
    def valid_host:
      type == "string" and
      test("^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$");
    def valid_port:
      type == "number" and floor == . and . >= 1 and . <= 65535;
    def valid_path:
      type == "string" and test("^/[A-Za-z0-9._~/-]+$") and
      (contains("//") | not) and (contains("..") | not);
    .schema == 1 and
    .node.name == $expected and
    (.node.name | valid_name) and
    (.node.domain | valid_host) and
    (.node.address | valid_host) and
    (.nginx.tls_port | valid_port) and
    (.xray.routes | type == "array") and
    all(.xray.routes[];
      (.name | valid_name) and
      (.path | valid_path) and
      (.port | valid_port) and
      (.public_port | valid_port) and
      (.target == "direct" or (.target | valid_name)) and
      (.profile == "plain" or .profile == "vlessenc-vision") and
      (.host == "" or (.host | valid_host)) and
      (.client_encryption | type == "string" and length <= 4096 and
        (test("[\u0000-\u001f\u007f]") | not)) and
      (.flow == "" or .flow == "xtls-rprx-vision") and
      (.security == "none" or .security == "tls") and
      (.direct | type == "boolean") and
      (.allow_insecure | type == "boolean")
    ) and
    (.xray.reality_inbounds | type == "array") and
    all(.xray.reality_inbounds[];
      (.name | valid_name) and
      (.port | valid_port) and
      (.path | valid_path) and
      (.server_names | type == "array" and length > 0 and
        all(.[]; valid_host)) and
      (.public_key | type == "string" and test("^[A-Za-z0-9_-]{20,128}$")) and
      (.short_ids | type == "array" and length > 0 and
        all(.[]; type == "string" and test("^[0-9a-fA-F]{2,32}$")))
    ) and
    (.hysteria2.enabled | type == "boolean") and
    (.hysteria2.port | valid_port) and
    (.hysteria2.obfs == "none" or .hysteria2.obfs == "salamander") and
    (.hysteria2.obfs_password | type == "string" and length <= 512 and
      (test("[\u0000-\u001f\u007f]") | not)) and
    (.hysteria2.insecure | type == "boolean")
  ' <<<"$entry" >/dev/null
}

subscription_worker_entries() {
  local node name report entry
  [[ "$(jq -r '.node.role' "$STATE_FILE")" != "exit" ]] || return 0
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    name="$(jq -r '.name' <<<"$node")"
    report="$CONTROL_DIR/reports/${name}.json"
    [[ -f "$report" ]] || continue
    entry="$(jq -ce '.entry // empty' "$report" 2>/dev/null || true)"
    [[ -n "$entry" ]] || continue
    if validate_worker_subscription_entry "$name" "$entry"; then
      printf '%s\n' "$entry"
    else
      warn "忽略从服务器 ${name} 回报的无效订阅入口参数"
    fi
  done < <(jq -c '(.paired_nodes // [])[]' "$STATE_FILE")
}

available_nodes_json() {
  {
    subscription_entry_from_state
    subscription_worker_entries
  } | jq -s -c '
    [
      .[] as $entry |
      ($entry.xray.routes[]? | {
        key: ($entry.node.name + "/xhttp/" + .name),
        label: (
          $entry.node.name + "-" +
          (if .target == "direct" then ""
           else (.target + "-") end) +
          (if .profile == "vlessenc-vision" then
             "VLESS-Encryption-XHTTP"
           else "XHTTP" end)
        ),
        protocol: "xhttp"
      }),
      ($entry.xray.reality_inbounds[]? | {
        key: ($entry.node.name + "/reality/" + .name),
        label: ($entry.node.name + "-Reality-XHTTP"),
        protocol: "reality"
      }),
      (if $entry.hysteria2.enabled then {
        key: ($entry.node.name + "/hy2"),
        label: ($entry.node.name + "-Hysteria2"),
        protocol: "hy2"
      } else empty end)
    ] | unique_by(.key)[]
  '
}

user_node_allowed() {
  local user="$1" key="$2"
  jq -e --arg key "$key" '
    (.enabled_nodes // ["*"]) as $nodes |
    ($nodes | index("*")) != null or ($nodes | index($key)) != null
  ' <<<"$user" >/dev/null
}

prompt_user_node_selection() {
  local current_json="${1:-[]}" allow_empty="${2:-false}"
  local row key label answer normalized default_numbers=""
  local i=0 current_all=false
  local -a rows=() selected=()
  local -A known=()
  mapfile -t rows < <(available_nodes_json)
  jq -e 'index("*") != null' <<<"$current_json" >/dev/null && current_all=true

  for row in "${rows[@]}"; do
    key="$(jq -r '.key' <<<"$row")"
    known["$key"]=1
  done
  if [[ "$current_all" != "true" ]]; then
    while IFS= read -r key; do
      [[ -n "$key" && -z "${known[$key]:-}" ]] || continue
      rows+=("$(jq -nc --arg key "$key" \
        '{key: $key, label: ($key + "（当前入口未在线）"), protocol: "offline"}')")
      known["$key"]=1
    done < <(jq -r '.[]' <<<"$current_json")
  fi
  (( ${#rows[@]} > 0 )) || die "目前没有可分配的节点，请先配置至少一个客户端入口"

  printf '\n%s【选择这个用户可以使用的节点】%s\n' "$C_BOLD" "$C_RESET" >&2
  printf '输入多个编号可同时开启；未选择的节点会对这个用户关闭。\n' >&2
  for row in "${rows[@]}"; do
    ((i+=1))
    key="$(jq -r '.key' <<<"$row")"
    label="$(jq -r '.label' <<<"$row")"
    if [[ "$current_all" == "true" ]] ||
       jq -e --arg key "$key" 'index($key) != null' <<<"$current_json" >/dev/null; then
      printf '  %d. %s  [已开启]\n' "$i" "$label" >&2
      default_numbers+="${default_numbers:+ }${i}"
    else
      printf '  %d. %s  [已关闭]\n' "$i" "$label" >&2
    fi
  done
  [[ "$allow_empty" != "true" ]] || printf '  0. 关闭该用户的全部节点\n' >&2

  while true; do
    if [[ -n "$default_numbers" ]]; then
      read -r -p "请输入编号，可多选（直接回车保持当前选择）[${default_numbers}]: " answer
      answer="${answer:-$default_numbers}"
    else
      read -r -p '请输入编号，可多选（例如 1 3）: ' answer
    fi
    if [[ "$answer" == "0" && "$allow_empty" == "true" ]]; then
      printf ''
      return
    fi
    if normalized="$(normalize_index_selection "$answer" "${#rows[@]}" false)"; then
      selected=()
      for i in $normalized; do
        selected+=("$(jq -r '.key' <<<"${rows[$((i - 1))]}")")
      done
      (IFS=,; printf '%s' "${selected[*]}")
      return
    fi
    warn "请输入列表中的编号；多个编号用空格或逗号分隔"
  done
}

vless_link_for_route() {
  local route="$1" user="$2" entry="$3"
  local uuid domain address port path profile encryption flow host query security
  local entry_name target protocol fragment
  uuid="$(jq -r '.uuid' <<<"$user")"
  domain="$(jq -r '.node.domain' <<<"$entry")"
  address="$(jq -r '.node.address' <<<"$entry")"
  if [[ "$(jq -r '.direct // false' <<<"$route")" == "true" ]]; then
    port="$(jq -r '.public_port // .port' <<<"$route")"
  else
    port="$(jq -r '.nginx.tls_port' <<<"$entry")"
  fi
  path="$(jq -r '.path' <<<"$route")"
  profile="$(jq -r '.profile' <<<"$route")"
  encryption="$(jq -r '.client_encryption // "none"' <<<"$route")"
  flow="$(jq -r '.flow // ""' <<<"$route")"
  host="$(jq -r --arg d "$domain" 'if (.host // "") == "" then $d else .host end' <<<"$route")"
  security="$(jq -r '.security // "tls"' <<<"$route")"
  [[ "$(jq -r '.direct // false' <<<"$route")" != "true" ]] || security="$(jq -r '.security // "tls"' <<<"$route")"
  query="encryption=$(urlencode "$encryption")&security=$(urlencode "$security")&sni=$(urlencode "$domain")&type=xhttp&host=$(urlencode "$host")&path=$(urlencode "$path")&mode=auto"
  if [[ "$(jq -r '.allow_insecure // false' <<<"$route")" == "true" ]]; then
    query+="&allowInsecure=1"
  fi
  [[ -z "$flow" ]] || query+="&flow=$(urlencode "$flow")"
  if [[ "$profile" == "vlessenc-vision" ]]; then
    local extra
    extra='{"xmux":{"maxConcurrency":"16-32","maxConnections":0,"cMaxReuseTimes":"64-128","cMaxLifetimeMs":0,"hMaxRequestTimes":"800-900","hKeepAlivePeriod":0}}'
    query+="&extra=$(urlencode "$extra")"
  fi
  entry_name="$(jq -r '.node.name' <<<"$entry")"
  target="$(jq -r '.target' <<<"$route")"
  protocol="XHTTP"
  [[ "$profile" != "vlessenc-vision" ]] || protocol="VLESS-Encryption-XHTTP"
  fragment="${entry_name}-${protocol}"
  [[ "$target" == "direct" ]] || fragment="${entry_name}-${target}-${protocol}"
  printf 'vless://%s@%s:%s?%s#%s\n' \
    "$uuid" "$address" "$port" "$query" "$(urlencode "$fragment")"
}

vless_link_for_reality() {
  local reality="$1" user="$2" entry="$3"
  local uuid address name port path sni public_key short_id query entry_name
  uuid="$(jq -r '.uuid' <<<"$user")"
  address="$(jq -r '.node.address' <<<"$entry")"
  name="$(jq -r '.name' <<<"$reality")"
  port="$(jq -r '.port' <<<"$reality")"
  path="$(jq -r '.path' <<<"$reality")"
  sni="$(jq -r '.server_names[0]' <<<"$reality")"
  # Derive the public key from the private key when Xray is available.
  public_key="$(jq -r '.public_key // ""' <<<"$reality")"
  short_id="$(jq -r '.short_ids[0]' <<<"$reality")"
  if [[ -z "$public_key" ]]; then
    warn "Reality $name has no public_key in state; client link omitted"
    return 0
  fi
  query="encryption=none&security=reality&sni=$(urlencode "$sni")&fp=chrome&pbk=$(urlencode "$public_key")&sid=$(urlencode "$short_id")&type=xhttp&path=$(urlencode "$path")&mode=auto"
  entry_name="$(jq -r '.node.name' <<<"$entry")"
  printf 'vless://%s@%s:%s?%s#%s\n' \
    "$uuid" "$address" "$port" "$query" \
    "$(urlencode "${entry_name}-Reality-XHTTP")"
}

hy2_link_for_user() {
  local user="$1" entry="$2" password address domain port query entry_name
  password="$(jq -r '.hy2_password' <<<"$user")"
  address="$(jq -r '.node.address' <<<"$entry")"
  domain="$(jq -r '.node.domain' <<<"$entry")"
  port="$(jq -r '.hysteria2.port' <<<"$entry")"
  query="sni=$(urlencode "$domain")"
  if [[ "$(jq -r '.hysteria2.insecure // false' <<<"$entry")" == "true" ]]; then
    query+="&insecure=1"
  fi
  if [[ "$(jq -r '.hysteria2.obfs' <<<"$entry")" != "none" ]]; then
    query+="&obfs=$(urlencode "$(jq -r '.hysteria2.obfs' <<<"$entry")")"
    query+="&obfs-password=$(urlencode "$(jq -r '.hysteria2.obfs_password' <<<"$entry")")"
  fi
  entry_name="$(jq -r '.node.name' <<<"$entry")"
  printf 'hysteria2://%s@%s:%s/?%s#%s\n' \
    "$(urlencode "$password")" "$address" "$port" "$query" \
    "$(urlencode "${entry_name}-Hysteria2")"
}

subscription_links_for_entry() {
  local user="$1" entry="$2" route reality route_name entry_name node_key
  entry_name="$(jq -r '.node.name' <<<"$entry")"
  while IFS= read -r route; do
    [[ -n "$route" ]] || continue
    route_name="$(jq -r '.name' <<<"$route")"
    node_key="${entry_name}/xhttp/${route_name}"
    user_node_allowed "$user" "$node_key" || continue
    vless_link_for_route "$route" "$user" "$entry"
  done < <(jq -c '.xray.routes[]?' <<<"$entry")
  while IFS= read -r reality; do
    [[ -n "$reality" ]] || continue
    node_key="${entry_name}/reality/$(jq -r '.name' <<<"$reality")"
    user_node_allowed "$user" "$node_key" || continue
    vless_link_for_reality "$reality" "$user" "$entry"
  done < <(jq -c '.xray.reality_inbounds[]?' <<<"$entry")
  if [[ "$(jq -r '.hysteria2.enabled' <<<"$entry")" == "true" ]] &&
     [[ "$(jq -r '.hy2_password // ""' <<<"$user")" != "" ]] &&
     user_node_allowed "$user" "${entry_name}/hy2"; then
    hy2_link_for_user "$user" "$entry"
  fi
}

subscription_plain() {
  local name="$1" user entry
  user="$(active_user_json "$name")" || die "用户不存在、已暂停或已过期：$name"
  entry="$(subscription_entry_from_state)"
  subscription_links_for_entry "$user" "$entry"
  if [[ "$(jq -r '.node.role' "$STATE_FILE")" != "exit" ]]; then
    while IFS= read -r entry; do
      [[ -n "$entry" ]] || continue
      subscription_links_for_entry "$user" "$entry"
    done < <(subscription_worker_entries)
  fi
}

render_subscriptions() {
  local target_dir="$1" user token plain
  [[ -n "$target_dir" && "$target_dir" != "/" ]] || die "Unsafe subscription directory"
  mkdir -p "$target_dir"
  find "$target_dir" -mindepth 1 -maxdepth 1 -type f -delete
  [[ "$(jq -r '.subscription.enabled // false' "$STATE_FILE")" == "true" ]] ||
    return 0
  while IFS= read -r user; do
    [[ -n "$user" ]] || continue
    token="$(jq -r '.subscription_token' <<<"$user")"
    valid_bearer_token "$token" || die "Invalid subscription token in state"
    valid_subscription_prefix "$(jq -r '.subscription_prefix' <<<"$user")" ||
      die "Invalid subscription prefix in state"
    plain="$(subscription_plain "$(jq -r '.name' <<<"$user")")"
    printf '%s' "$plain" | base64 -w 0 >"${target_dir}/${token}"
    chmod 600 "${target_dir}/${token}"
  done < <(jq -c '.users[] | select(
    .enabled == true and
    (.expires_at == null or .expires_at == "" or
     (((.expires_at | fromdateiso8601?) // 0) > now))
  )' "$STATE_FILE")
}

cmd_render() {
  local out="$GENERATED_DIR"
  while (($#)); do
    case "$1" in
      --out) out="$2"; shift 2 ;;
      --help) echo "Usage: etxr render [--out DIR]"; return ;;
      *) die "Unknown render option: $1" ;;
    esac
  done
  require_state
  state_lock_acquire
  ensure_control_state
  render_control_desired
  mkdir -p "$out"
  render_xray "$out/xray.json"
  jq -e 'type == "object"' "$out/xray.json" >/dev/null ||
    die "生成的 Xray 配置无效"
  if [[ "$(jq -r '.nginx.mode' "$STATE_FILE")" != "disabled" ]]; then
    render_nginx_paths "$out/nginx-paths.conf"
    [[ -s "$out/nginx-paths.conf" ]] || die "生成的 nginx Path 配置为空"
  else
    rm -f "$out/nginx-paths.conf" "$out/nginx-standalone.conf"
  fi
  if [[ "$(jq -r '.nginx.mode' "$STATE_FILE")" == "standalone" ]]; then
    render_nginx_standalone "$out/nginx-standalone.conf"
    [[ -s "$out/nginx-standalone.conf" ]] || die "生成的 nginx 配置为空"
  fi
  if [[ "$(jq -r '.nginx.shared_tcp443 // false' "$STATE_FILE")" == "true" ]]; then
    render_nginx_stream "$out/nginx-stream.conf"
    [[ -s "$out/nginx-stream.conf" ]] || die "生成的 nginx stream 配置为空"
    if [[ "$(jq -r '.nginx.mode' "$STATE_FILE")" == "standalone" ]]; then
      render_nginx_stream_loader "$out/nginx-stream-loader.conf"
      [[ -s "$out/nginx-stream-loader.conf" ]] ||
        die "生成的 nginx stream 加载配置为空"
    else
      rm -f "$out/nginx-stream-loader.conf"
    fi
  else
    rm -f "$out/nginx-stream.conf" "$out/nginx-stream-loader.conf"
  fi
  if [[ "$(jq -r '.hysteria2.enabled' "$STATE_FILE")" == "true" ]]; then
    render_sing_box "$out/sing-box.json"
    jq -e 'type == "object"' "$out/sing-box.json" >/dev/null ||
      die "生成的 sing-box 配置无效"
  else
    rm -f "$out/sing-box.json"
  fi
  render_limits "$out/limits.json"
  render_subscriptions "$out/subscriptions"
  chmod -R go-rwx "$out"
  log "Rendered configuration in $out"
  state_lock_release
}

nginx_bin() {
  local configured pid running
  configured="$(jq -r '.nginx.binary // empty' "$STATE_FILE")"
  if [[ -n "$configured" && -x "$configured" ]]; then
    printf '%s' "$configured"
  elif command -v pgrep >/dev/null 2>&1; then
    while IFS= read -r pid; do
      running="$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)"
      if [[ -n "$running" && -x "$running" &&
            "$(basename "$running")" == "nginx" ]]; then
        printf '%s' "$running"
        return
      fi
    done < <(pgrep -f 'nginx: master process' 2>/dev/null || true)
    if [[ -x /www/server/nginx/sbin/nginx ]]; then
      printf '%s' /www/server/nginx/sbin/nginx
    elif [[ -x /usr/sbin/nginx ]]; then
      printf '%s' /usr/sbin/nginx
    elif command -v nginx >/dev/null 2>&1; then
      command -v nginx
    else
      return 1
    fi
  elif [[ -x /www/server/nginx/sbin/nginx ]]; then
    printf '%s' /www/server/nginx/sbin/nginx
  elif [[ -x /usr/sbin/nginx ]]; then
    printf '%s' /usr/sbin/nginx
  elif command -v nginx >/dev/null 2>&1; then
    command -v nginx
  else
    return 1
  fi
}

nginx_supports_stream_preread() {
  local nb
  nb="$(nginx_bin)" || return 1
  "$nb" -V 2>&1 | grep -q -- '--with-stream_ssl_preread_module'
}

check_baota_shared_nginx_layout() {
  local nb="$1" mode stream_path hits main_conf auto_rebind
  nginx_supports_stream_preread ||
    die "当前 nginx 未编译 stream_ssl_preread_module，无法进行 Reality/XHTTP TCP 443 分流"
  mode="$(jq -r '.nginx.mode' "$STATE_FILE")"
  stream_path="$(jq -r '.nginx.stream_path // empty' "$STATE_FILE")"
  if [[ "$mode" == "standalone" ]]; then
    main_conf="/etc/nginx/nginx.conf"
    [[ -f "$main_conf" ]] || die "未找到 /etc/nginx/nginx.conf"
    grep -Eq 'include[[:space:]]+/etc/nginx/modules-enabled/\*\.conf' "$main_conf" ||
      die "标准 nginx 未加载 modules-enabled/*.conf，无法添加 stream 分流"
    hits="$(
      while IFS= read -r -d '' candidate; do
        [[ "$candidate" != "$stream_path" ]] || continue
        nginx_tcp443_file_has_active "$candidate" && printf '%s\n' "$candidate"
      done < <(nginx_config_candidates)
    )"
    [[ -z "$hits" ]] || {
      printf '%s\n' "$hits" >&2
      die "标准 nginx 中已有其他 TCP 443 监听，无法自动共用"
    }
    [[ -n "$nb" ]]
    return
  fi

  main_conf="/www/server/nginx/conf/nginx.conf"
  if [[ -f "$main_conf" ]] &&
     ! grep -Eq 'include[[:space:]]+/www/server/panel/vhost/nginx/tcp/\*\.conf' \
       "$main_conf"; then
    die "宝塔主配置未包含 tcp/*.conf，无法加载 ETXR 的 stream 分流配置"
  fi
  if [[ -d /www/server/panel/vhost/nginx ]]; then
    hits="$(
      while IFS= read -r candidate; do
        if grep -E \
          '^[[:space:]]*listen[[:space:]]+443([[:space:];]|[[:space:]]+ssl|[[:space:]]+reuseport)' \
          "$candidate" 2>/dev/null |
          grep -Evq '(^|[[:space:]])quic([[:space:];]|$)'; then
          printf '%s\n' "$candidate"
        fi
      done < <(grep -RIlE \
        '^[[:space:]]*listen[[:space:]]+443([[:space:];]|[[:space:]]+ssl|[[:space:]]+reuseport)' \
        /www/server/panel/vhost/nginx --exclude-dir=tcp 2>/dev/null || true)
    )"
    auto_rebind="$(jq -r '.nginx.auto_rebind_https // false' "$STATE_FILE")"
    if [[ -n "$hits" && "$auto_rebind" != "true" ]]; then
      printf '%s\n' "$hits" >&2
      die "宝塔 HTTPS vhost 仍直接监听 TCP 443；请先改为 127.0.0.1:8443（不会自动修改其他网站）"
    fi
    hits="$(grep -RIlE '^[[:space:]]*listen[[:space:]]+443[[:space:]]*;' \
      /www/server/panel/vhost/nginx/tcp 2>/dev/null |
      grep -vFx "$stream_path" || true)"
    [[ -z "$hits" ]] || {
      printf '%s\n' "$hits" >&2
      die "宝塔 tcp 目录已有其他 TCP 443 stream 配置，请先处理端口冲突"
    }
  fi
  [[ -n "$nb" ]]
}

validate_state_semantics() {
  local errors=0
  if ! jq -e '
    ([.xray.routes[].name] | length == (unique | length)) and
    ([.xray.routes[].path] | length == (unique | length)) and
    ([.xray.routes[].port] | length == (unique | length)) and
    ([.xray.exits[].name] | length == (unique | length)) and
    ([.users[].name] | length == (unique | length))
  ' "$STATE_FILE" >/dev/null; then
    warn "Duplicate route, exit, user, path, or port"
    errors=1
  fi
  if jq -e '
    [.xray.routes[] | select(.target != "direct") | .target] -
    [.xray.exits[].name] | length > 0
  ' "$STATE_FILE" >/dev/null; then
    warn "One or more routes reference a missing exit"
    errors=1
  fi
  local exit_errors="" exit_name="" exit_field="" exit_reason=""
  if ! exit_errors="$(jq -r '
    def valid_address:
      if type == "string" then test("^[A-Za-z0-9.-]+$") else false end;
    def valid_port:
      if type == "number" then floor == . and . >= 1 and . <= 65535
      else false end;
    def valid_uuid:
      if type == "string" then
        test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$")
      else false end;
    def valid_path:
      if type == "string" then test("^/[A-Za-z0-9._~/-]+$") else false end;
    def valid_socks_credential:
      if type == "string" then
        length <= 255 and (test("[\u0000-\u001f\u007f]") | not)
      else false end;

    .xray.exits[]? as $exit |
    ($exit.name // "<未命名出口>") as $name |
    ($exit.transport // "") as $transport |
    ($exit.socks_username // "") as $socks_username |
    ($exit.socks_password // "") as $socks_password |
    [
      if ($transport == "tls" or $transport == "reality" or
          $transport == "none" or $transport == "socks5") then empty
      else [$name, "transport", "仅支持 tls、reality、none 或 socks5"] end,
      if ($exit.address | valid_address) then empty
      else [$name, "address", "必须填写 IPv4 地址或域名，不能包含协议、端口或路径"] end,
      if ($exit.port | valid_port) then empty
      else [$name, "port", "必须是 1 到 65535 之间的整数"] end,
      if $transport == "socks5" and ($socks_username | valid_socks_credential | not) then
        [$name, "SOCKS5 用户名", "不能超过 255 个字符，也不能包含控制字符"]
      else empty end,
      if $transport == "socks5" and ($socks_password | valid_socks_credential | not) then
        [$name, "SOCKS5 密码", "不能超过 255 个字符，也不能包含控制字符"]
      else empty end,
      if $transport == "socks5" and
          ((($socks_username == "") and ($socks_password != "")) or
           (($socks_username != "") and ($socks_password == ""))) then
        [$name, "SOCKS5 认证", "用户名和密码必须同时填写或同时留空"]
      else empty end,
      if $transport != "socks5" and ($exit.uuid | valid_uuid | not) then
        [$name, "UUID", "格式不正确，请重新生成标准 UUID"]
      else empty end,
      if $transport != "socks5" and ($exit.network // "xhttp") == "xhttp" and
          ($exit.path | valid_path | not) then
        [$name, "Path", "XHTTP 出口必须填写以 / 开头的 Path"]
      else empty end
    ][] | @tsv
  ' "$STATE_FILE")"; then
    warn "读取出口配置失败：state.json 结构不完整或内容格式错误"
    errors=1
  elif [[ -n "$exit_errors" ]]; then
    while IFS=$'\t' read -r exit_name exit_field exit_reason; do
      warn "出口 ${exit_name} 的 ${exit_field} 无效：${exit_reason}"
    done <<<"$exit_errors"
    errors=1
  fi
  if jq -e '
    [.xray.routes[] | select(.profile == "vlessenc-vision" and
      ((.decryption // "none") == "none" or (.client_encryption // "none") == "none"))]
    | length > 0
  ' "$STATE_FILE" >/dev/null; then
    warn "A vlessenc-vision route is missing its encryption pair"
    errors=1
  fi
  if ! jq -e '
    (([.xray.routes[]?.port] +
      [.xray.reality_inbounds[]? | (.listen_port // .port)] +
      [.xray.relay_inbounds[]?.port] +
      [
        (.data_plane.limiter_port // 18181),
        (.data_plane.xray_api_port // 18182),
        (if (.hysteria2.enabled // false) then
          (.data_plane.hy2_bridge_port // 18183)
        else empty end)
      ] +
      (if (.control.enabled // false) then
        [(.control.port // 18180)]
      else [] end)) |
      map(select(type == "number"))) as $tcp |
    ($tcp | length) == ($tcp | unique | length)
  ' "$STATE_FILE" >/dev/null; then
    warn "Xray TCP ports conflict inside the state"
    errors=1
  fi
  if ! jq -e '
    all(.users[];
      ((.enabled_nodes // ["*"]) |
        type == "array" and
        length == (unique | length) and
        all(.[]; type == "string" and
          test("^\\*$|^[A-Za-z0-9][A-Za-z0-9._-]{0,63}/((xhttp|reality)/[A-Za-z0-9][A-Za-z0-9._-]{0,63}|hy2)$"))) and
      ((.speed_limit.up_mbps // 0) |
        type == "number" and floor == . and . >= 0 and . <= 100000) and
      ((.speed_limit.down_mbps // 0) |
        type == "number" and floor == . and . >= 0 and . <= 100000) and
      ((.usage_epoch // "") | type == "string" and length <= 128) and
      ((.domain_epoch // "") | type == "string" and length <= 128)
    ) and
    ((.data_plane.limiter_listen // "127.0.0.1") == "127.0.0.1") and
    ((.domain_audit // {
      enabled: false,
      retention_days: 30,
      max_domains_per_user: 500
    }) as $audit |
      ($audit | type == "object") and
      ($audit.enabled | type == "boolean") and
      ($audit.retention_days | type == "number" and floor == . and
        . >= 1 and . <= 365) and
      ($audit.max_domains_per_user | type == "number" and floor == . and
        . >= 10 and . <= 5000))
  ' "$STATE_FILE" >/dev/null; then
    warn "Invalid per-user speed limit, domain audit, or data-plane state"
    errors=1
  fi
  if ! jq -e '
    ((.hysteria2.shared_udp443 // false) | type == "boolean") and
    ((.hysteria2.shared_udp443 // false) == false or
      ((.hysteria2.enabled // false) == true and .hysteria2.port == 443))
  ' "$STATE_FILE" >/dev/null; then
    warn "Hysteria2 共用 UDP 443 的状态无效：必须启用 HY2 并使用端口 443"
    errors=1
  fi
  if ! jq -e '
    def valid_ipv4:
      type == "string" and
      (split(".") | length == 4 and
        all(.[]; test("^[0-9]{1,3}$") and
          ((tonumber) >= 0 and (tonumber) <= 255)));
    def valid_peer:
      if . == "" then true
      elif type != "string" then false
      else
        (try capture("^(?<host>[A-Za-z0-9.-]+):(?<port>[0-9]{1,5})$") catch null) as $peer |
        ($peer != null and
          ($peer.host | test("^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$")) and
          (($peer.port | tonumber) >= 1 and ($peer.port | tonumber) <= 65535))
      end;
    (.easytier.enabled // false) == false or
    ((.easytier.ipv4 | valid_ipv4) and
     (.easytier.network_name | type == "string" and test("^[A-Za-z0-9._:-]{1,64}$")) and
     (.easytier.network_secret | type == "string" and test("^[A-Za-z0-9._:@+-]{1,256}$")) and
     (.easytier.tcp_port | type == "number" and floor == . and . >= 1 and . <= 65535) and
     ((.easytier.peer // "") | valid_peer))
  ' "$STATE_FILE" >/dev/null; then
    warn "Invalid EasyTier state values"
    errors=1
  fi
  if [[ "$(jq -r '.nginx.shared_tcp443 // false' "$STATE_FILE")" == "true" ]]; then
    if ! jq -e '
      ((.nginx.mode == "snippet") or (.nginx.mode == "standalone")) and
      (.nginx.tls_port == 443) and
      (.nginx.https_listen_port | type == "number" and . != 443) and
      ((.nginx.auto_rebind_https // false) | type == "boolean") and
      ((.nginx.auto_rebind_https // false) == false or .nginx.mode == "snippet") and
      ([.xray.reality_inbounds[]?] | length > 0) and
      (all(.xray.reality_inbounds[]?; .port == 443 and
        (.listen // "127.0.0.1") == "127.0.0.1")) and
      ([.xray.reality_inbounds[]?.server_names[]?] |
        length == (unique | length))
    ' "$STATE_FILE" >/dev/null; then
      warn "Shared TCP 443 state is incomplete or Reality SNI values are duplicated"
      errors=1
    fi
  fi
  return "$errors"
}

port_conflict_check() {
  command -v ss >/dev/null 2>&1 || return 0
  local port
  while IFS= read -r port; do
    if ss -lntH "sport = :$port" 2>/dev/null | grep -q .; then
      warn "TCP $port is already listening (may be the currently running managed service)"
    fi
  done < <(jq -r '.xray.reality_inbounds[]? |
    (.listen_port // .port)' "$STATE_FILE")
  if [[ "$(jq -r '.hysteria2.enabled' "$STATE_FILE")" == "true" ]]; then
    port="$(jq -r '.hysteria2.port' "$STATE_FILE")"
    if ss -lnuH "sport = :$port" 2>/dev/null | grep -q .; then
      warn "UDP $port is already listening (may be the currently running managed service)"
    fi
  fi
}

cmd_validate() {
  require_state
  state_lock_acquire
  local temp rc=0 nb
  temp="$(mktemp -d)"
  cmd_render --out "$temp"
  jq -e . "$temp/xray.json" >/dev/null || rc=1
  [[ ! -f "$temp/sing-box.json" ]] || jq -e . "$temp/sing-box.json" >/dev/null || rc=1
  validate_state_semantics || rc=1

  if [[ -x "$XRAY_BIN" ]]; then
    "$XRAY_BIN" run -test -config "$temp/xray.json" || rc=1
  else
    warn "Xray binary not found; skipped Xray runtime validation"
  fi
  if [[ -f "$temp/sing-box.json" ]]; then
    if [[ -x "$SING_BOX_BIN" ]]; then
      "$SING_BOX_BIN" check -c "$temp/sing-box.json" || rc=1
    else
      warn "sing-box binary not found; skipped Hysteria2 runtime validation"
    fi
  fi
  if [[ "$(jq -r '.nginx.mode' "$STATE_FILE")" != "disabled" ]]; then
    if nb="$(nginx_bin 2>/dev/null)"; then
      if [[ "$(jq -r '.nginx.shared_tcp443 // false' "$STATE_FILE")" == "true" ]]; then
        check_baota_shared_nginx_layout "$nb" || rc=1
      fi
      "$nb" -t || {
        warn "Current nginx configuration test failed"
        rc=1
      }
    else
      warn "nginx binary not found; skipped nginx runtime validation"
    fi
  fi
  port_conflict_check
  if (( rc != 0 )); then
    rm -rf "$temp"
    die "Validation failed"
  fi
  rm -rf "$temp"
  state_lock_release
  log "Validation passed"
}

backup_file() {
  local source="$1" dest_dir="$2"
  [[ -e "$source" ]] || return 0
  mkdir -p "$dest_dir"
  cp -a "$source" "$dest_dir/$(basename "$source")"
}

cmd_backup() {
  require_state
  local stamp dest suffix=0
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dest="${BACKUP_DIR}/${stamp}"
  while [[ -e "$dest" ]]; do
    suffix="$((suffix + 1))"
    dest="${BACKUP_DIR}/${stamp}-${suffix}"
  done
  LAST_BACKUP_DIR="$dest"
  mkdir -p "$dest"
  cp -a "$STATE_FILE" "$dest/state.json"
  backup_file "$(jq -r '.xray.config_path' "$STATE_FILE")" "$dest"
  backup_file "$(jq -r '.hysteria2.config_path' "$STATE_FILE")" "$dest"
  backup_file "$(jq -r '.nginx.snippet_path' "$STATE_FILE")" "$dest"
  backup_file "$(jq -r '.nginx.standalone_path' "$STATE_FILE")" "$dest"
  backup_file "$(jq -r '.nginx.paths_path // empty' "$STATE_FILE")" "$dest"
  backup_file "$(jq -r '.nginx.stream_path // empty' "$STATE_FILE")" "$dest"
  backup_file "$(jq -r '.nginx.stream_loader_path // empty' "$STATE_FILE")" "$dest"
  backup_file "$EASYTIER_CONFIG" "$dest"
  backup_file "$LIMITER_CONFIG" "$dest"
  backup_file "$USAGE_FILE" "$dest"
  backup_file "$DOMAIN_FILE" "$dest"
  log "Backup created: $dest"
}

valid_migration_password() {
  (( ${#1} >= 12 && ${#1} <= 1024 ))
}

valid_migration_iterations() {
  local iterations="$1"
  [[ "$iterations" =~ ^[1-9][0-9]{5,6}$ ]] &&
    (( iterations >= 100000 && iterations <= 2000000 ))
}

migration_password_from_file() {
  local file="$1" password
  [[ -f "$file" && -r "$file" && ! -L "$file" ]] ||
    die "迁移密码文件不存在、不可读或是符号链接"
  (( $(wc -c <"$file") <= 4096 )) || die "迁移密码文件过大"
  IFS= read -r password <"$file" || true
  valid_migration_password "$password" || die "迁移密码至少需要 12 个字符"
  printf '%s' "$password"
}

migration_hmac_key() {
  local password="$1" salt="$2" iterations="$3"
  printf '%s' "$password" | python3 -c '
import hashlib
import sys

password = sys.stdin.buffer.read()
salt = bytes.fromhex(sys.argv[1])
iterations = int(sys.argv[2])
print(hashlib.pbkdf2_hmac("sha256", password, salt, iterations, 32).hex())
' "$salt" "$iterations"
}

migration_hmac_tag() {
  local key="$1" manifest="$2" ciphertext="$3"
  printf '%s' "$key" | python3 -c '
import hashlib
import hmac
import sys

key = bytes.fromhex(sys.stdin.read().strip())
digest = hmac.new(key, digestmod=hashlib.sha256)
for path in sys.argv[1:]:
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
print(digest.hexdigest())
' "$manifest" "$ciphertext"
}

migration_hmac_verify() {
  local key="$1" manifest="$2" ciphertext="$3" expected="$4"
  printf '%s' "$key" | python3 -c '
import hashlib
import hmac
import sys

key = bytes.fromhex(sys.stdin.read().strip())
expected = sys.argv[1].strip().lower()
if len(expected) != 64 or any(c not in "0123456789abcdef" for c in expected):
    raise SystemExit(1)
digest = hmac.new(key, digestmod=hashlib.sha256)
for path in sys.argv[2:]:
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
raise SystemExit(0 if hmac.compare_digest(digest.hexdigest(), expected) else 1)
' "$expected" "$manifest" "$ciphertext"
}

migration_extract_container() {
  local package="$1" destination="$2"
  python3 - "$package" "$destination" <<'PY'
import os
import shutil
import sys
import tarfile

package, destination = sys.argv[1:]
allowed = {
    "manifest.json": 64 * 1024,
    "payload.enc": 128 * 1024 * 1024,
    "payload.hmac": 128,
}
with tarfile.open(package, "r:") as archive:
    members = archive.getmembers()
    if [member.name for member in members] != list(allowed):
        raise SystemExit("invalid migration container members")
    os.makedirs(destination, mode=0o700, exist_ok=True)
    for member in members:
        if not member.isfile() or member.size > allowed[member.name]:
            raise SystemExit("invalid migration container entry")
        source = archive.extractfile(member)
        if source is None:
            raise SystemExit("unreadable migration container entry")
        target = os.path.join(destination, member.name)
        with source, open(target, "wb") as output:
            shutil.copyfileobj(source, output)
        os.chmod(target, 0o600)
PY
}

migration_extract_payload() {
  local payload="$1" destination="$2"
  python3 - "$payload" "$destination" <<'PY'
import os
import shutil
import sys
import tarfile

payload, destination = sys.argv[1:]
allowed = {
    "state.json": (16 * 1024 * 1024, 0o600),
    "usage.json": (32 * 1024 * 1024, 0o600),
    "domains.json": (64 * 1024 * 1024, 0o600),
    "keys/pair-signing.key": (64 * 1024, 0o600),
    "keys/pair-signing.pub": (64 * 1024, 0o644),
}
with tarfile.open(payload, "r:gz") as archive:
    members = archive.getmembers()
    names = [member.name for member in members]
    if len(names) != len(set(names)) or "state.json" not in names:
        raise SystemExit("invalid migration payload members")
    if any(name not in allowed for name in names):
        raise SystemExit("unsupported migration payload entry")
    has_private = "keys/pair-signing.key" in names
    has_public = "keys/pair-signing.pub" in names
    if has_private != has_public:
        raise SystemExit("incomplete pair signing key")
    os.makedirs(destination, mode=0o700, exist_ok=True)
    for member in members:
        limit, mode = allowed[member.name]
        if not member.isfile() or member.size > limit:
            raise SystemExit("invalid migration payload entry")
        source = archive.extractfile(member)
        if source is None:
            raise SystemExit("unreadable migration payload entry")
        target = os.path.join(destination, member.name)
        os.makedirs(os.path.dirname(target), mode=0o700, exist_ok=True)
        with source, open(target, "wb") as output:
            shutil.copyfileobj(source, output)
        os.chmod(target, mode)
PY
}

migration_unpack_package() {
  local package="$1" password="$2" destination="$3"
  local container manifest ciphertext tag salt iterations hmac_key payload
  [[ -f "$package" && -r "$package" && ! -L "$package" ]] ||
    die "迁移包不存在、不可读或是符号链接"
  (( $(stat -c '%s' "$package") <= MIGRATION_PACKAGE_MAX_BYTES )) ||
    die "迁移包超过 128 MiB 限制"
  valid_migration_password "$password" || die "迁移密码至少需要 12 个字符"
  need_cmd python3
  need_cmd openssl
  need_jq

  container="$(mktemp -d)"
  migration_extract_container "$package" "$container" || {
    rm -rf "$container"
    die "迁移包结构无效"
  }
  manifest="$container/manifest.json"
  ciphertext="$container/payload.enc"
  tag="$(tr -d '\r\n' <"$container/payload.hmac")"
  jq -e '
    .format == 1 and
    .state_schema == 1 and
    (.created_at | type == "string") and
    (.source.version | type == "string" and
      test("^[0-9]{1,6}\\.[0-9]{1,6}\\.[0-9]{1,6}$")) and
    (.source.node | type == "string" and length >= 1 and length <= 64) and
    (.source.role == "gateway" or .source.role == "exit" or
      .source.role == "hybrid") and
    .encryption.cipher == "aes-256-ctr" and
    .encryption.kdf == "pbkdf2-hmac-sha256" and
    (.encryption.iterations | type == "number" and
      floor == . and . >= 100000 and . <= 2000000) and
    .authentication.algorithm == "hmac-sha256" and
    (.authentication.salt | type == "string" and
      test("^[0-9a-f]{32}$")) and
    .includes_certificates == false
  ' "$manifest" >/dev/null || {
    rm -rf "$container"
    die "迁移包元数据无效或加密参数不受支持"
  }
  salt="$(jq -r '.authentication.salt' "$manifest")"
  iterations="$(jq -r '.encryption.iterations' "$manifest")"
  hmac_key="$(migration_hmac_key "$password" "$salt" "$iterations")"
  migration_hmac_verify "$hmac_key" "$manifest" "$ciphertext" "$tag" || {
    rm -rf "$container"
    die "迁移密码错误或迁移包已被修改"
  }
  payload="$container/payload.tar.gz"
  if ! printf '%s' "$password" | openssl enc -d -aes-256-ctr \
      -pbkdf2 -iter "$iterations" -md sha256 -pass stdin \
      -in "$ciphertext" -out "$payload" 2>/dev/null; then
    rm -rf "$container"
    die "迁移数据解密失败"
  fi
  rm -rf "$destination"
  migration_extract_payload "$payload" "$destination" || {
    rm -rf "$container" "$destination"
    die "迁移数据结构无效"
  }
  cp -a "$manifest" "$destination/manifest.json"
  rm -rf "$container"

  jq -e '.schema_version == 1' "$destination/state.json" >/dev/null ||
    die "迁移包中的 state.json 无效或版本不受支持"
  for payload in "$destination/usage.json" "$destination/domains.json"; do
    [[ ! -e "$payload" ]] || jq -e 'type == "object"' "$payload" >/dev/null ||
      die "迁移包中的 $(basename "$payload") 不是有效 JSON 对象"
  done
  if [[ -f "$destination/keys/pair-signing.key" ]]; then
    local private_digest public_digest
    private_digest="$(openssl pkey -in "$destination/keys/pair-signing.key" \
      -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    public_digest="$(openssl pkey -pubin \
      -in "$destination/keys/pair-signing.pub" -outform DER 2>/dev/null |
      sha256sum | awk '{print $1}')"
    [[ -n "$private_digest" && "$private_digest" == "$public_digest" ]] ||
      die "迁移包中的 Pair 签名公私钥不匹配"
  fi
}

migration_prepare_state() {
  local source="$1" destination="$2" domain="$3" address="$4"
  local mode="$5" cert="$6" key="$7"
  local snippet="" stream_path="" stream_loader="" auto_rebind=false
  local saved_state
  need_jq
  valid_hostname "$domain" || die "迁移后的入口域名无效"
  valid_hostname "$address" || die "迁移后的客户端连接地址无效"
  [[ "$mode" == "disabled" || "$mode" == "snippet" ||
     "$mode" == "standalone" ]] || die "迁移后的 nginx 模式无效"
  [[ -z "$cert" ]] || valid_absolute_path "$cert" || die "证书路径无效"
  [[ -z "$key" ]] || valid_absolute_path "$key" || die "证书私钥路径无效"
  if [[ "$mode" == "disabled" ]] &&
     [[ "$(jq -r '.nginx.mode' "$source")" != "disabled" ]]; then
    die "原配置需要 nginx，迁移后不能关闭 nginx"
  fi
  if [[ "$mode" == "snippet" ]]; then
    snippet="/www/server/panel/vhost/nginx/extension/${domain}/etxr.conf"
    if [[ "$(jq -r '.nginx.shared_tcp443 // false' "$source")" == "true" ]]; then
      stream_path="/www/server/panel/vhost/nginx/tcp/etxr.conf"
      auto_rebind=true
    fi
  elif [[ "$mode" == "standalone" ]] &&
       [[ "$(jq -r '.nginx.shared_tcp443 // false' "$source")" == "true" ]]; then
    stream_path="/etc/nginx/stream-conf.d/etxr.conf"
    stream_loader="/etc/nginx/modules-enabled/99-etxr-stream.conf"
  fi

  jq --arg domain "$domain" --arg address "$address" \
    --arg mode "$mode" --arg cert "$cert" --arg key "$key" \
    --arg snippet "$snippet" --arg stream "$stream_path" \
    --arg stream_loader "$stream_loader" \
    --arg xray_config "${RUNTIME_DIR}/live/xray.json" \
    --arg sing_config "${RUNTIME_DIR}/live/sing-box.json" \
    --arg paths "${RUNTIME_DIR}/live/nginx-paths.conf" \
    --argjson auto_rebind "$auto_rebind" '
    .node.domain = $domain |
    .node.address = $address |
    .nginx.mode = $mode |
    .nginx.certificate = $cert |
    .nginx.certificate_key = $key |
    .nginx.snippet_path = $snippet |
    .nginx.standalone_path = "/etc/nginx/conf.d/etxr.conf" |
    .nginx.paths_path = $paths |
    .nginx.stream_path = $stream |
    .nginx.stream_loader_path = $stream_loader |
    .nginx.auto_rebind_https = $auto_rebind |
    .nginx.web_root = "/var/www/etxr" |
    del(.nginx.binary) |
    .xray.config_path = $xray_config |
    .xray.routes |= map(
      if (.security // "none") == "tls" then
        .certificate = $cert | .certificate_key = $key
      else . end
    ) |
    .hysteria2.config_path = $sing_config |
    .hysteria2.certificate = $cert |
    .hysteria2.certificate_key = $key |
    if (.easytier.enabled // false) and
       ((.easytier.peer // "") == "") then
      .easytier.public_endpoint = $address
    else . end
  ' "$source" >"$destination" || die "生成迁移后的状态失败"
  chmod 600 "$destination"
  saved_state="$STATE_FILE"
  STATE_FILE="$destination"
  validate_state_semantics || {
    STATE_FILE="$saved_state"
    die "迁移后的状态语义检查失败"
  }
  STATE_FILE="$saved_state"
}

migration_export_impl() {
  local output="$1" password="$2" temp stage package_dir payload
  local salt hmac_key tag stamp source_files_json output_tmp
  local -a payload_files=(state.json)
  valid_migration_iterations "$MIGRATION_KDF_ITERATIONS" ||
    die "迁移加密迭代次数必须是 100000 到 2000000 之间的整数"
  temp="$(mktemp -d)"
  trap 'rm -rf -- "$temp"' EXIT
  stage="$temp/stage"
  package_dir="$temp/package"
  mkdir -p "$stage/keys" "$package_dir"
  install -m 600 "$STATE_FILE" "$stage/state.json"
  if [[ -f "$USAGE_FILE" ]]; then
    jq -e 'type == "object"' "$USAGE_FILE" >/dev/null ||
      die "当前 usage.json 无效，已停止导出"
    install -m 600 "$USAGE_FILE" "$stage/usage.json"
    payload_files+=(usage.json)
  fi
  if [[ -f "$DOMAIN_FILE" ]]; then
    jq -e 'type == "object"' "$DOMAIN_FILE" >/dev/null ||
      die "当前 domains.json 无效，已停止导出"
    install -m 600 "$DOMAIN_FILE" "$stage/domains.json"
    payload_files+=(domains.json)
  fi
  if [[ -f "$PAIR_PRIVATE_KEY" || -f "$PAIR_PUBLIC_KEY" ]]; then
    [[ -f "$PAIR_PRIVATE_KEY" && -f "$PAIR_PUBLIC_KEY" ]] ||
      die "当前 Pair 签名密钥不完整，已停止导出"
    install -m 600 "$PAIR_PRIVATE_KEY" "$stage/keys/pair-signing.key"
    install -m 644 "$PAIR_PUBLIC_KEY" "$stage/keys/pair-signing.pub"
    payload_files+=(keys/pair-signing.key keys/pair-signing.pub)
  fi
  payload="$temp/payload.tar.gz"
  tar -C "$stage" -czf "$payload" "${payload_files[@]}"
  if ! printf '%s' "$password" | openssl enc -aes-256-ctr -pbkdf2 \
      -iter "$MIGRATION_KDF_ITERATIONS" -md sha256 -salt -pass stdin \
      -in "$payload" -out "$package_dir/payload.enc" 2>/dev/null; then
    die "迁移数据加密失败"
  fi
  salt="$(openssl rand -hex 16)"
  source_files_json="$(printf '%s\n' "${payload_files[@]}" |
    jq -Rsc 'split("\n")[:-1]')"
  jq -n --arg version "$VERSION" \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg node "$(jq -r '.node.name' "$STATE_FILE")" \
    --arg role "$(jq -r '.node.role' "$STATE_FILE")" \
    --arg salt "$salt" --argjson iterations "$MIGRATION_KDF_ITERATIONS" \
    --argjson files "$source_files_json" '
    {
      format: 1,
      state_schema: 1,
      created_at: $created,
      source: {version: $version, node: $node, role: $role},
      encryption: {
        cipher: "aes-256-ctr",
        kdf: "pbkdf2-hmac-sha256",
        iterations: $iterations
      },
      authentication: {algorithm: "hmac-sha256", salt: $salt},
      payload_files: $files,
      includes_certificates: false
    }
  ' >"$package_dir/manifest.json"
  hmac_key="$(migration_hmac_key "$password" "$salt" \
    "$MIGRATION_KDF_ITERATIONS")"
  tag="$(migration_hmac_tag "$hmac_key" "$package_dir/manifest.json" \
    "$package_dir/payload.enc")"
  printf '%s\n' "$tag" >"$package_dir/payload.hmac"
  chmod 600 "$package_dir"/*

  ensure_parent "$output"
  output_tmp="$(mktemp "$(dirname "$output")/.etxr-migration.XXXXXX")"
  rm -f "$output_tmp"
  tar -C "$package_dir" -cf "$output_tmp" \
    manifest.json payload.enc payload.hmac
  chmod 600 "$output_tmp"
  if [[ -e "$output" && "$FORCE" -ne 1 ]]; then
    rm -f "$output_tmp"
    die "迁移包已存在：$output；如需覆盖请添加 --force"
  fi
  mv -f "$output_tmp" "$output"
  stamp="$(sha256sum "$output" | awk '{print substr($1,1,16)}')"
  log "加密迁移包已生成：$output"
  log "迁移包校验标识：$stamp"
  rm -rf "$temp"
  trap - EXIT
}

cmd_migration_export() {
  local output="" password_file="" password confirm_password
  while (($#)); do
    case "$1" in
      --out)
        (($# >= 2)) || die "--out 后面缺少迁移包路径"
        output="$2"; shift 2 ;;
      --password-file)
        (($# >= 2)) || die "--password-file 后面缺少文件路径"
        password_file="$2"; shift 2 ;;
      --help)
        echo "Usage: etxr migration export --out /root/node.etxrm [--password-file FILE]"
        return ;;
      *) die "Unknown migration export option: $1" ;;
    esac
  done
  require_state
  [[ -n "$output" ]] || die "migration export requires --out FILE"
  valid_absolute_path "$output" || die "迁移包输出路径必须是安全的绝对路径"
  need_cmd python3
  need_cmd openssl
  need_cmd tar
  need_cmd sha256sum
  if [[ -n "$password_file" ]]; then
    password="$(migration_password_from_file "$password_file")"
  else
    [[ -t 0 ]] || die "非交互导出必须使用 --password-file"
    password="$(prompt_secret '设置迁移包密码（至少 12 个字符）')"
    confirm_password="$(prompt_secret '再次输入迁移包密码')"
    [[ "$password" == "$confirm_password" ]] || die "两次输入的迁移密码不一致"
    valid_migration_password "$password" || die "迁移密码至少需要 12 个字符"
  fi
  (migration_export_impl "$output" "$password")
}

migration_state_needs_certificate() {
  jq -e '
    .nginx.mode != "disabled" or
    (.hysteria2.enabled // false) or
    any(.xray.routes[]?; (.security // "none") == "tls")
  ' "$1" >/dev/null
}

migration_backup_target_file() {
  local source="$1" backup="$2" name="$3"
  [[ -e "$source" ]] || return 0
  install -m 600 "$source" "$backup/$name"
  : >"$backup/$name.present"
}

migration_restore_target_file() {
  local target="$1" backup="$2" name="$3" mode="$4"
  if [[ -f "$backup/$name.present" ]]; then
    ensure_parent "$target"
    install -m "$mode" "$backup/$name" "$target"
  else
    rm -f "$target"
  fi
}

migration_install_target_files() {
  local prepared="$1" unpacked="$2" data_name data_source data_target
  install -m 600 "$prepared" "$STATE_FILE" || return 1
  for data_name in usage.json domains.json; do
    if [[ "$data_name" == "usage.json" ]]; then
      data_source="$unpacked/usage.json"
      data_target="$USAGE_FILE"
    else
      data_source="$unpacked/domains.json"
      data_target="$DOMAIN_FILE"
    fi
    if [[ -f "$data_source" ]]; then
      ensure_parent "$data_target" || return 1
      install -m 600 "$data_source" "$data_target" || return 1
    else
      rm -f "$data_target" || return 1
    fi
  done
  mkdir -p "$PAIR_KEY_DIR" || return 1
  chmod 700 "$PAIR_KEY_DIR" || return 1
  if [[ -f "$unpacked/keys/pair-signing.key" ]]; then
    install -m 600 "$unpacked/keys/pair-signing.key" \
      "$PAIR_PRIVATE_KEY" || return 1
    install -m 644 "$unpacked/keys/pair-signing.pub" \
      "$PAIR_PUBLIC_KEY" || return 1
  else
    rm -f "$PAIR_PRIVATE_KEY" "$PAIR_PUBLIC_KEY" || return 1
  fi
}

migration_restore_target_files() {
  local backup="$1" failed=0
  migration_restore_target_file "$STATE_FILE" "$backup" state.json 600 || failed=1
  migration_restore_target_file "$USAGE_FILE" "$backup" usage.json 600 || failed=1
  migration_restore_target_file "$DOMAIN_FILE" "$backup" domains.json 600 || failed=1
  migration_restore_target_file "$PAIR_PRIVATE_KEY" "$backup" \
    pair-signing.key 600 || failed=1
  migration_restore_target_file "$PAIR_PUBLIC_KEY" "$backup" \
    pair-signing.pub 644 || failed=1
  (( failed == 0 ))
}

migration_import_impl() {
  local package="$1" password="$2" domain="$3" address="$4"
  local mode="$5" cert="$6" certificate_key="$7"
  local temp source prepared role old_domain components="xray,dataplane"
  local backup stamp suffix=0
  temp="$(mktemp -d)"
  trap 'rm -rf -- "$temp"' EXIT
  migration_unpack_package "$package" "$password" "$temp/unpacked"
  source="$temp/unpacked/state.json"
  old_domain="$(jq -r '.node.domain' "$source")"
  role="$(jq -r '.node.role' "$source")"
  if [[ "$role" != "exit" && "$domain" != "$old_domain" ]] &&
     (( $(jq '(.paired_nodes // []) | length' "$source") > 0 )); then
    if (( ! FORCE )); then
      die "主服务器已有从服务器，迁移时应继续使用原域名 $old_domain；如已安排重新配对可添加 --force"
    fi
    warn "主服务器域名已改变，现有从服务器仍保存旧控制地址，需要重新配对或更新"
  fi
  prepared="$temp/prepared-state.json"
  migration_prepare_state "$source" "$prepared" "$domain" "$address" \
    "$mode" "$cert" "$certificate_key"
  if migration_state_needs_certificate "$prepared"; then
    tls_certificate_is_usable "$cert" "$certificate_key" ||
      die "新服务器证书不存在、已过期或与私钥不匹配"
    tls_certificate_matches_name "$cert" "$domain" ||
      die "新服务器证书不包含迁移后的域名 $domain"
  fi
  [[ "$(jq -r '.easytier.enabled // false' "$prepared")" != "true" ]] ||
    components+=",easytier"
  [[ "$(jq -r '.hysteria2.enabled // false' "$prepared")" != "true" ]] ||
    components+=",sing-box"
  [[ "$mode" != "standalone" ]] || components+=",nginx"
  cmd_install --components "$components"

  mkdir -p "$BACKUP_DIR"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="$BACKUP_DIR/migration-import-${stamp}"
  while [[ -e "$backup" ]]; do
    suffix="$((suffix + 1))"
    backup="$BACKUP_DIR/migration-import-${stamp}-${suffix}"
  done
  mkdir -p "$backup"
  migration_backup_target_file "$STATE_FILE" "$backup" state.json
  migration_backup_target_file "$USAGE_FILE" "$backup" usage.json
  migration_backup_target_file "$DOMAIN_FILE" "$backup" domains.json
  migration_backup_target_file "$PAIR_PRIVATE_KEY" "$backup" pair-signing.key
  migration_backup_target_file "$PAIR_PUBLIC_KEY" "$backup" pair-signing.pub
  printf '%s\n' "$package" >"$backup/source-package.txt"

  state_lock_acquire
  if ! migration_install_target_files "$prepared" "$temp/unpacked"; then
    migration_restore_target_files "$backup" ||
      warn "恢复导入前状态时有文件失败，请检查：$backup"
    state_lock_release
    die "写入迁移状态失败，已尝试恢复新服务器原有 ETXR 状态"
  fi

  if ! (cmd_apply); then
    migration_restore_target_files "$backup" ||
      warn "恢复导入前状态时有文件失败，请检查：$backup"
    if [[ -f "$STATE_FILE" ]] && ! (cmd_apply); then
      warn "旧 ETXR 状态已经恢复，但旧配置重新应用失败，请运行一键检查"
    fi
    state_lock_release
    die "迁移配置应用失败，已恢复新服务器原有 ETXR 状态"
  fi
  state_lock_release
  log "迁移完成；导入前状态保存在：$backup"
  rm -rf "$temp"
  trap - EXIT
}

cmd_migration_import_inner() {
  local package="" password_file="" password="" domain="" address=""
  local mode="" cert="" certificate_key="" temp source old_domain
  local old_address source_mode is_baota=0 default_cert default_key
  while (($#)); do
    case "$1" in
      --password-file)
        (($# >= 2)) || die "--password-file 后面缺少文件路径"
        password_file="$2"; shift 2 ;;
      --domain)
        (($# >= 2)) || die "--domain 后面缺少域名"
        domain="$2"; shift 2 ;;
      --address)
        (($# >= 2)) || die "--address 后面缺少连接地址"
        address="$2"; shift 2 ;;
      --nginx-mode)
        (($# >= 2)) || die "--nginx-mode 后面缺少模式"
        mode="$2"; shift 2 ;;
      --cert)
        (($# >= 2)) || die "--cert 后面缺少证书路径"
        cert="$2"; shift 2 ;;
      --key)
        (($# >= 2)) || die "--key 后面缺少证书私钥路径"
        certificate_key="$2"; shift 2 ;;
      --help)
        cat <<'EOF'
Usage:
  etxr migration import FILE [--password-file FILE] [--domain DOMAIN]
    [--address HOST] [--nginx-mode snippet|standalone|disabled]
    [--cert FILE --key FILE]
EOF
        return ;;
      -*) die "不认识的迁移导入选项：$1" ;;
      *)
        [[ -z "$package" ]] || die "只能指定一个迁移包"
        package="$1"
        shift ;;
    esac
  done
  [[ -n "$package" ]] || die "migration import requires FILE"
  if [[ -f "$STATE_FILE" && "$FORCE" -ne 1 ]]; then
    die "这台服务器已经存在 ETXR 配置；请在未初始化的新服务器导入，确需覆盖时使用全局 --force"
  fi
  need_root
  install_base_packages
  if [[ -n "$password_file" ]]; then
    password="$(migration_password_from_file "$password_file")"
  else
    [[ -t 0 ]] || die "非交互导入必须使用 --password-file"
    password="$(prompt_secret '输入迁移包密码')"
  fi

  temp="$(mktemp -d)"
  trap 'rm -rf -- "$temp"' EXIT
  migration_unpack_package "$package" "$password" "$temp"
  source="$temp/state.json"
  old_domain="$(jq -r '.node.domain' "$source")"
  old_address="$(jq -r '.node.address' "$source")"
  source_mode="$(jq -r '.nginx.mode' "$source")"
  if [[ -t 0 ]]; then
    printf '\n%s【新服务器入口信息】%s\n' "$C_BOLD" "$C_RESET"
    domain="$(prompt_hostname_value '迁移后使用的入口域名' "${domain:-$old_domain}")"
    address="$(prompt_hostname_value '客户端连接地址（通常与入口域名相同）' \
      "${address:-${domain:-$old_address}}")"
  else
    domain="${domain:-$old_domain}"
    address="${address:-$domain}"
  fi
  if [[ -x /www/server/nginx/sbin/nginx ]]; then
    is_baota=1
    printf '%s✓ 检测到宝塔，将复用宝塔 nginx，不安装第二套 nginx。%s\n' \
      "$C_GREEN" "$C_RESET"
  fi
  if [[ "$source_mode" == "disabled" ]]; then
    mode="disabled"
  elif (( is_baota )); then
    if [[ -t 0 ]] && ! menu_confirm "确认迁移后继续使用宝塔 nginx"; then
      rm -rf "$temp"
      die "已取消迁移；检测到宝塔时不会安装第二套 nginx"
    fi
    mode="snippet"
  else
    mode="${mode:-standalone}"
    [[ "$mode" == "standalone" ]] ||
      die "未检测到宝塔，原配置需要 nginx 时必须使用 standalone 模式"
    printf '%s未检测到宝塔，将使用标准 nginx。%s\n' "$C_YELLOW" "$C_RESET"
  fi
  if migration_state_needs_certificate "$source"; then
    if (( is_baota )); then
      default_cert="/www/server/panel/vhost/cert/${domain}/fullchain.pem"
      default_key="/www/server/panel/vhost/cert/${domain}/privkey.pem"
    else
      default_cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
      default_key="/etc/letsencrypt/live/${domain}/privkey.pem"
    fi
    if [[ -t 0 ]]; then
      printf '\n%s【新服务器证书】%s\n' "$C_BOLD" "$C_RESET"
      printf '证书不会从旧服务器迁移，请填写新服务器已经存在的证书。\n'
      cert="$(prompt_value '证书 fullchain.pem 的绝对路径' "${cert:-$default_cert}")"
      certificate_key="$(prompt_value '证书 privkey.pem 的绝对路径' \
        "${certificate_key:-$default_key}")"
    else
      cert="${cert:-$default_cert}"
      certificate_key="${certificate_key:-$default_key}"
    fi
  else
    cert=""
    certificate_key=""
  fi
  rm -rf "$temp"
  trap - EXIT
  migration_import_impl "$package" "$password" "$domain" "$address" \
    "$mode" "$cert" "$certificate_key"
}

cmd_migration_import() {
  (cmd_migration_import_inner "$@")
}

cmd_migration() {
  local action="${1:-}"
  shift || true
  case "$action" in
    export) cmd_migration_export "$@" ;;
    import) cmd_migration_import "$@" ;;
    *) die "Usage: etxr migration export|import" ;;
  esac
}

install_data_helper() {
  local arch asset base tmp expected actual candidate_version target_tmp=""
  local backup="" stamp
  if [[ -n "${ETXR_DATAPLANE_SOURCE:-}" ]]; then
    [[ -x "$ETXR_DATAPLANE_SOURCE" ]] ||
      die "ETXR_DATAPLANE_SOURCE 不是可执行文件"
    candidate_version="$("$ETXR_DATAPLANE_SOURCE" version 2>/dev/null || true)"
    [[ "$candidate_version" == "$VERSION" || "${ETXR_DATAPLANE_ALLOW_DEV:-0}" == "1" ]] ||
      die "本地数据面版本不匹配：需要 ${VERSION}，得到 ${candidate_version:-未知}"
    mkdir -p "$(dirname "$DATAPLANE_BIN")" "$BACKUP_DIR/dataplane-binary"
    target_tmp="$(mktemp "$(dirname "$DATAPLANE_BIN")/.etxr-dataplane.XXXXXX")"
    install -m 755 "$ETXR_DATAPLANE_SOURCE" "$target_tmp"
    if [[ -e "$DATAPLANE_BIN" ]]; then
      stamp="$(date -u +%Y%m%dT%H%M%SZ)"
      backup="$BACKUP_DIR/dataplane-binary/etxr-dataplane-${stamp}"
      cp -a "$DATAPLANE_BIN" "$backup"
    fi
    if ! mv -f "$target_tmp" "$DATAPLANE_BIN" ||
       { [[ "${ETXR_DATAPLANE_ALLOW_DEV:-0}" != "1" ]] &&
         [[ "$("$DATAPLANE_BIN" version 2>/dev/null || true)" != "$VERSION" ]]; }; then
      rm -f "$target_tmp"
      if [[ -n "$backup" && -e "$backup" ]]; then
        cp -a "$backup" "$DATAPLANE_BIN"
      fi
      die "安装本地 ETXR 数据面失败，已恢复旧版本"
    fi
    return
  fi
  if [[ -x "$DATAPLANE_BIN" ]] &&
     [[ "$("$DATAPLANE_BIN" version 2>/dev/null || true)" == "$VERSION" ]]; then
    return
  fi
  need_cmd curl
  need_cmd sha256sum
  arch="$(detect_arch_dataplane)"
  asset="etxr-dataplane-linux-${arch}"
  base="${DATAPLANE_DOWNLOAD_BASE%/}"
  tmp="$(mktemp -d)"
  curl --proto '=https' --tlsv1.2 -fL \
    "$base/checksums.txt" -o "$tmp/checksums.txt" || {
      rm -rf "$tmp"
      die "下载 ETXR 数据面校验文件失败"
    }
  curl --proto '=https' --tlsv1.2 -fL \
    "$base/$asset" -o "$tmp/$asset" || {
      rm -rf "$tmp"
      die "下载 ETXR 数据面失败"
    }
  expected="$(awk -v n="$asset" '
    $2 == n || $2 == ("*" n) {print $1; exit}
  ' "$tmp/checksums.txt")"
  actual="$(sha256sum "$tmp/$asset" | awk '{print $1}')"
  if [[ ! "$expected" =~ ^[0-9a-fA-F]{64}$ ||
        "${expected,,}" != "${actual,,}" ]]; then
    rm -rf "$tmp"
    die "ETXR 数据面 SHA256 校验失败"
  fi
  chmod 755 "$tmp/$asset"
  candidate_version="$("$tmp/$asset" version 2>/dev/null || true)"
  if [[ "$candidate_version" != "$VERSION" ]]; then
    rm -rf "$tmp"
    die "ETXR 数据面版本不匹配：需要 ${VERSION}，得到 ${candidate_version:-未知}"
  fi

  mkdir -p "$(dirname "$DATAPLANE_BIN")" "$BACKUP_DIR/dataplane-binary"
  target_tmp="$(mktemp "$(dirname "$DATAPLANE_BIN")/.etxr-dataplane.XXXXXX")"
  install -m 755 "$tmp/$asset" "$target_tmp"
  if [[ -e "$DATAPLANE_BIN" ]]; then
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    backup="$BACKUP_DIR/dataplane-binary/etxr-dataplane-${stamp}"
    cp -a "$DATAPLANE_BIN" "$backup"
  fi
  if ! mv -f "$target_tmp" "$DATAPLANE_BIN" ||
     [[ "$("$DATAPLANE_BIN" version 2>/dev/null || true)" != "$VERSION" ]]; then
    rm -f "$target_tmp"
    if [[ -n "$backup" && -e "$backup" ]]; then
      cp -a "$backup" "$DATAPLANE_BIN"
    fi
    rm -rf "$tmp"
    die "安装 ETXR 数据面失败，已恢复旧版本"
  fi
  rm -rf "$tmp"
  log "Installed ETXR data plane ${VERSION} (${arch})"
}

install_control_helper() {
  local tmp
  tmp="$(mktemp)"
  # ETXR_CONTROL_HELPER_BEGIN
  cat >"$tmp" <<'PY'
#!/usr/bin/env python3
import argparse
import asyncio
import hashlib
import hmac
import json
import os
import random
import subprocess
import tempfile
import time
from pathlib import Path
from urllib.parse import urlsplit

import aiohttp
from aiohttp import web

MAX_CONFIG_BYTES = 1024 * 1024
MAX_CLOCK_SKEW_SECONDS = 300
DOMAIN_REPORT_INTERVAL_SECONDS = 300


def read_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def atomic_text(path, value):
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(
        prefix=target.name + ".", dir=target.parent
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            os.fchmod(handle.fileno(), 0o600)
            handle.write(value)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, target)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def atomic_json(path, value):
    atomic_text(
        path,
        json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n",
    )


class Hub:
    def __init__(self, state_path, control_dir, etxr_bin, subscription_dir):
        self.state_path = state_path
        self.control_dir = Path(control_dir)
        self.etxr_bin = etxr_bin
        self.subscription_dir = subscription_dir
        self.connection_limit = asyncio.Semaphore(128)

    def node(self, node_id):
        state = read_json(self.state_path)
        for node in state.get("paired_nodes", []):
            if node.get("name") == node_id:
                return node
        return None

    def authorized(self, request, node):
        supplied = request.headers.get("Authorization", "")
        expected = "Bearer " + str(node.get("control_token", ""))
        return hmac.compare_digest(supplied, expected)

    def desired_bytes(self, node_id):
        return (self.control_dir / "nodes" / f"{node_id}.json").read_bytes()

    def save_report(self, node_id, report, request=None):
        if not isinstance(report, dict):
            raise ValueError("report must be an object")
        if len(json.dumps(report, ensure_ascii=False)) > 1024 * 1024:
            raise ValueError("report is too large")
        report_path = self.control_dir / "reports" / f"{node_id}.json"
        try:
            previous = read_json(report_path)
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            previous = {}
        if not isinstance(previous, dict):
            previous = {}
        for key in ("usage", "entry", "domains"):
            if key not in report and isinstance(previous.get(key), dict):
                report[key] = previous[key]
        entry = report.get("entry")
        entry_changed = (
            isinstance(entry, dict)
            and entry.get("schema") == 1
            and isinstance(entry.get("node"), dict)
            and entry["node"].get("name") == node_id
            and entry != previous.get("entry")
        )
        report["node_id"] = node_id
        report["received_at"] = int(time.time())
        if request is not None:
            report["remote"] = request.remote
        atomic_json(report_path, report)
        return entry_changed

    def refresh_subscriptions(self):
        env = dict(os.environ)
        env["ETXR_CONTROL_DIR"] = str(self.control_dir)
        env["ETXR_SUBSCRIPTIONS"] = self.subscription_dir
        try:
            result = subprocess.run(
                [
                    self.etxr_bin,
                    "--state",
                    self.state_path,
                    "subscriptions",
                    "refresh",
                ],
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                timeout=30,
                check=False,
            )
        except (OSError, subprocess.SubprocessError) as error:
            print(f"etxr-control: subscription refresh failed: {error}", flush=True)
            return
        if result.returncode != 0:
            message = result.stderr.decode(errors="replace")[-1000:]
            print(
                f"etxr-control: subscription refresh exited "
                f"{result.returncode}: {message}",
                flush=True,
            )

    async def health(self, request):
        return web.json_response({"status": "ok"})

    async def config(self, request):
        node_id = request.match_info["node_id"]
        node = self.node(node_id)
        if node is None or not self.authorized(request, node):
            raise web.HTTPUnauthorized()
        try:
            body = self.desired_bytes(node_id)
        except FileNotFoundError:
            raise web.HTTPNotFound()
        signature = hmac.new(
            node["control_token"].encode(), body, hashlib.sha256
        ).hexdigest()
        return web.Response(
            body=body,
            content_type="application/json",
            headers={"X-ETXR-Signature": signature, "Cache-Control": "no-store"},
        )

    async def report(self, request):
        node_id = request.match_info["node_id"]
        node = self.node(node_id)
        if node is None or not self.authorized(request, node):
            raise web.HTTPUnauthorized()
        try:
            report = await request.json()
        except (json.JSONDecodeError, aiohttp.ContentTypeError):
            raise web.HTTPBadRequest()
        try:
            entry_changed = self.save_report(node_id, report, request)
        except ValueError:
            raise web.HTTPBadRequest()
        if entry_changed:
            await asyncio.to_thread(self.refresh_subscriptions)
        return web.json_response({"status": "accepted"})

    async def websocket(self, request):
        if self.connection_limit.locked():
            raise web.HTTPServiceUnavailable(text="too many control connections")
        async with self.connection_limit:
            return await self._websocket(request)

    async def _websocket(self, request):
        node_id = request.match_info["node_id"]
        node = self.node(node_id)
        if node is None or not self.authorized(request, node):
            raise web.HTTPUnauthorized()
        ws = web.WebSocketResponse(heartbeat=25)
        await ws.prepare(request)
        last_version = ""
        last_heartbeat = 0.0
        self.save_report(node_id, {"status": "connected"}, request)
        while not ws.closed:
            try:
                desired = json.loads(self.desired_bytes(node_id))
                version = str(desired["version"])
                if version != last_version:
                    await ws.send_json({"type": "update", "version": version})
                    last_version = version
            except (FileNotFoundError, KeyError, json.JSONDecodeError):
                pass
            now = time.monotonic()
            if now - last_heartbeat >= 20:
                await ws.send_json({"type": "heartbeat", "time": int(time.time())})
                last_heartbeat = now
            try:
                message = await ws.receive(timeout=1)
            except asyncio.TimeoutError:
                continue
            if message.type == aiohttp.WSMsgType.TEXT:
                try:
                    payload = json.loads(message.data)
                except json.JSONDecodeError:
                    continue
                if payload.get("type") == "report":
                    try:
                        entry_changed = self.save_report(
                            node_id, payload, request
                        )
                    except ValueError:
                        continue
                    if entry_changed:
                        await asyncio.to_thread(self.refresh_subscriptions)
            elif message.type in {
                aiohttp.WSMsgType.CLOSE,
                aiohttp.WSMsgType.CLOSED,
                aiohttp.WSMsgType.ERROR,
            }:
                break
        return ws

    def app(self):
        app = web.Application(client_max_size=2 * 1024 * 1024)
        app.router.add_get("/health", self.health)
        app.router.add_get("/ws/{node_id}", self.websocket)
        app.router.add_get("/config/{node_id}", self.config)
        app.router.add_post("/report/{node_id}", self.report)
        return app


class Agent:
    def __init__(self, state_path, etxr_bin, usage_file, domain_file):
        self.state_path = state_path
        self.etxr_bin = etxr_bin
        self.usage_file = usage_file
        self.domain_file = domain_file
        self.next_domain_report = 0.0
        self.version_path = str(Path(state_path).parent / "control-version")
        self.issued_at_path = str(Path(state_path).parent / "control-issued-at")

    def settings(self):
        return read_json(self.state_path)["control"]["agent"]

    def current_version(self):
        try:
            return Path(self.version_path).read_text(encoding="utf-8").strip()
        except FileNotFoundError:
            return ""

    def current_issued_at(self):
        try:
            value = Path(self.issued_at_path).read_text(encoding="utf-8").strip()
            return int(value)
        except (FileNotFoundError, ValueError):
            return 0

    def usage(self):
        try:
            value = read_json(self.usage_file)
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            return {"updated_at": 0, "users": {}}
        users = value.get("users", {})
        if not isinstance(users, dict):
            users = {}
        return {
            "updated_at": int(value.get("updated_at", 0)),
            "users": users,
        }

    def domains(self):
        try:
            path = Path(self.domain_file)
            if path.stat().st_size > 32 * 1024 * 1024:
                raise ValueError("domain ledger is too large")
            value = read_json(path)
        except (FileNotFoundError, json.JSONDecodeError, OSError, ValueError):
            return {"schema": 1, "updated_at": 0, "node": "", "users": {}}
        if (not isinstance(value, dict) or value.get("schema") != 1 or
                not isinstance(value.get("users"), dict)):
            return {"schema": 1, "updated_at": 0, "node": "", "users": {}}
        result = {}
        # Keep reports comfortably below the hub's 1 MiB request limit. The
        # complete per-node ledger remains available on the node itself.
        remaining = 1500
        for name in sorted(value["users"]):
            user = value["users"].get(name)
            if not isinstance(name, str) or not isinstance(user, dict):
                continue
            records = user.get("domains", {})
            if not isinstance(records, dict):
                records = {}
            selected = []
            for domain, record in records.items():
                if not isinstance(domain, str) or not isinstance(record, dict):
                    continue
                try:
                    connections = max(0, int(record.get("connections", 0)))
                    first_seen = max(0, int(record.get("first_seen", 0)))
                    last_seen = max(0, int(record.get("last_seen", 0)))
                except (TypeError, ValueError):
                    continue
                if not domain or len(domain) > 253 or connections == 0 or last_seen == 0:
                    continue
                selected.append((last_seen, domain, {
                    "connections": connections,
                    "first_seen": first_seen or last_seen,
                    "last_seen": last_seen,
                }))
            selected.sort(key=lambda item: (-item[0], item[1]))
            selected = selected[:remaining]
            remaining -= len(selected)
            try:
                unresolved = max(0, int(user.get("unresolved", 0)))
            except (TypeError, ValueError):
                unresolved = 0
            result[name] = {
                "uuid": str(user.get("uuid", "")),
                "domain_epoch": str(user.get("domain_epoch", "")),
                "unresolved": unresolved,
                "domains": {item[1]: item[2] for item in selected},
            }
            if remaining == 0:
                break
        try:
            updated_at = max(0, int(value.get("updated_at", 0)))
        except (TypeError, ValueError):
            updated_at = 0
        return {
            "schema": 1,
            "updated_at": updated_at,
            "node": str(value.get("node", "")),
            "users": result,
        }

    def entry_snapshot(self):
        state = read_json(self.state_path)
        node = state.get("node", {})
        nginx = state.get("nginx", {})
        xray = state.get("xray", {})
        hysteria2 = state.get("hysteria2", {})
        routes = []
        for route in xray.get("routes", []):
            routes.append({
                "name": route.get("name", ""),
                "path": route.get("path", ""),
                "port": route.get("port", 0),
                "public_port": route.get("public_port", route.get("port", 0)),
                "target": route.get("target", "direct"),
                "profile": route.get("profile", "plain"),
                "host": route.get("host", ""),
                "client_encryption": route.get("client_encryption", "none"),
                "flow": route.get("flow", ""),
                "security": route.get("security", "tls"),
                "direct": bool(route.get("direct", False)),
                "allow_insecure": bool(route.get("allow_insecure", False)),
            })
        realities = []
        for reality in xray.get("reality_inbounds", []):
            realities.append({
                "name": reality.get("name", ""),
                "port": reality.get("port", 0),
                "path": reality.get("path", ""),
                "server_names": reality.get("server_names", []),
                "public_key": reality.get("public_key", ""),
                "short_ids": reality.get("short_ids", []),
            })
        return {
            "schema": 1,
            "node": {
                "name": node.get("name", ""),
                "domain": node.get("domain", ""),
                "address": node.get("address", ""),
            },
            "nginx": {"tls_port": nginx.get("tls_port", 443)},
            "xray": {
                "routes": routes,
                "reality_inbounds": realities,
            },
            "hysteria2": {
                "enabled": bool(hysteria2.get("enabled", False)),
                "port": hysteria2.get("port", 443),
                "obfs": hysteria2.get("obfs", "none"),
                "obfs_password": hysteria2.get("obfs_password", ""),
                "insecure": bool(hysteria2.get("insecure", False)),
            },
        }

    @staticmethod
    def validate_base_url(value):
        parsed = urlsplit(value)
        if parsed.scheme == "https" and parsed.hostname:
            return True
        return parsed.scheme == "http" and parsed.hostname in {"127.0.0.1", "localhost", "::1"}

    async def report(self, session, base_url, node_id, payload):
        payload = dict(payload)
        payload["hostname"] = os.uname().nodename
        payload["usage"] = self.usage()
        domains = None
        if time.monotonic() >= self.next_domain_report:
            domains = self.domains()
            payload["domains"] = domains
        payload["entry"] = self.entry_snapshot()
        try:
            async with session.post(
                f"{base_url}/report/{node_id}", json=payload
            ) as response:
                await response.read()
                if response.status < 400 and domains is not None:
                    self.next_domain_report = (
                        time.monotonic() + DOMAIN_REPORT_INTERVAL_SECONDS
                    )
        except aiohttp.ClientError:
            pass

    async def synchronize(self, session, expected_version=None):
        settings = self.settings()
        base_url = settings["base_url"].rstrip("/")
        if not self.validate_base_url(base_url):
            raise RuntimeError("control base_url must use HTTPS")
        node_id = settings["node_id"]
        token = settings["token"]
        async with session.get(f"{base_url}/config/{node_id}") as response:
            response.raise_for_status()
            if (response.content_length is not None and
                    response.content_length > MAX_CONFIG_BYTES):
                raise RuntimeError("configuration response is too large")
            body = await response.content.read(MAX_CONFIG_BYTES + 1)
            if len(body) > MAX_CONFIG_BYTES:
                raise RuntimeError("configuration response is too large")
            signature = response.headers.get("X-ETXR-Signature", "")
        calculated = hmac.new(token.encode(), body, hashlib.sha256).hexdigest()
        if not hmac.compare_digest(signature, calculated):
            raise RuntimeError("configuration signature mismatch")
        bundle = json.loads(body)
        if bundle.get("node_id") != node_id or not isinstance(bundle.get("users"), list):
            raise RuntimeError("invalid configuration bundle")
        issued_at = bundle.get("issued_at")
        if not isinstance(issued_at, int) or issued_at <= 0:
            raise RuntimeError("configuration has no valid issue time")
        if issued_at > int(time.time()) + MAX_CLOCK_SKEW_SECONDS:
            raise RuntimeError("configuration issue time is in the future")
        current_issued_at = self.current_issued_at()
        if current_issued_at and issued_at < current_issued_at:
            raise RuntimeError("refusing replayed configuration")
        version = str(bundle.get("version", ""))
        if expected_version and version != expected_version:
            raise RuntimeError("configuration version changed during download")
        if version == self.current_version():
            if issued_at > current_issued_at:
                atomic_text(self.issued_at_path, str(issued_at) + "\n")
            await self.report(
                session, base_url, node_id,
                {"type": "report", "status": "current", "version": version},
            )
            return
        env = dict(os.environ)
        env["ETXR_AGENT_APPLY"] = "1"
        process = await asyncio.create_subprocess_exec(
            self.etxr_bin,
            "control",
            "apply",
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=env,
        )
        apply_payload = {"users": bundle["users"]}
        if isinstance(bundle.get("domain_audit"), dict):
            apply_payload["domain_audit"] = bundle["domain_audit"]
        stdout, stderr = await process.communicate(
            json.dumps(apply_payload, separators=(",", ":")).encode()
        )
        if process.returncode != 0:
            message = (stderr or stdout).decode(errors="replace")[-2000:]
            await self.report(
                session, base_url, node_id,
                {"type": "report", "status": "failed", "version": version,
                 "message": message},
            )
            raise RuntimeError(f"etxr apply failed with code {process.returncode}")
        atomic_text(self.version_path, version + "\n")
        atomic_text(self.issued_at_path, str(issued_at) + "\n")
        await self.report(
            session, base_url, node_id,
            {"type": "report", "status": "applied", "version": version},
        )

    async def run(self):
        backoff = 2
        while True:
            try:
                settings = self.settings()
                base_url = settings["base_url"].rstrip("/")
                node_id = settings["node_id"]
                token = settings["token"]
                if not self.validate_base_url(base_url):
                    raise RuntimeError("control base_url must use HTTPS")
                ws_url = base_url.replace("https://", "wss://", 1).replace(
                    "http://", "ws://", 1
                )
                headers = {"Authorization": "Bearer " + token}
                timeout = aiohttp.ClientTimeout(total=None, connect=20, sock_read=360)
                async with aiohttp.ClientSession(headers=headers, timeout=timeout) as session:
                    async with session.ws_connect(
                        f"{ws_url}/ws/{node_id}", heartbeat=25,
                        max_msg_size=64 * 1024,
                    ) as ws:
                        backoff = 2
                        next_check = time.monotonic() + 300
                        next_report = time.monotonic() + 60
                        while True:
                            now = time.monotonic()
                            receive_timeout = max(
                                1.0, min(
                                    60.0,
                                    next_check - now,
                                    next_report - now,
                                )
                            )
                            try:
                                message = await ws.receive(timeout=receive_timeout)
                            except asyncio.TimeoutError:
                                now = time.monotonic()
                                if now >= next_check:
                                    await self.synchronize(session)
                                    next_check = time.monotonic() + 300
                                if now >= next_report:
                                    await self.report(
                                        session, base_url, node_id,
                                        {
                                            "type": "report",
                                            "status": "current",
                                            "version": self.current_version(),
                                        },
                                    )
                                    next_report = time.monotonic() + 60
                                continue
                            if message.type == aiohttp.WSMsgType.TEXT:
                                payload = json.loads(message.data)
                                if payload.get("type") == "update":
                                    await self.synchronize(session, str(payload["version"]))
                                    next_check = time.monotonic() + 300
                            elif message.type in {
                                aiohttp.WSMsgType.CLOSE,
                                aiohttp.WSMsgType.CLOSED,
                                aiohttp.WSMsgType.ERROR,
                            }:
                                break
                            if time.monotonic() >= next_check:
                                await self.synchronize(session)
                                next_check = time.monotonic() + 300
                            if time.monotonic() >= next_report:
                                await self.report(
                                    session, base_url, node_id,
                                    {
                                        "type": "report",
                                        "status": "current",
                                        "version": self.current_version(),
                                    },
                                )
                                next_report = time.monotonic() + 60
            except (aiohttp.ClientError, asyncio.TimeoutError, KeyError,
                    json.JSONDecodeError, OSError, RuntimeError) as error:
                print(f"etxr-agent: {error}", flush=True)
            await asyncio.sleep(backoff + random.random())
            backoff = min(backoff * 2, 60)


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="mode", required=True)
    hub_parser = subparsers.add_parser("hub")
    hub_parser.add_argument("--state", required=True)
    hub_parser.add_argument("--control-dir", required=True)
    hub_parser.add_argument("--etxr-bin", default="/usr/local/sbin/etxr")
    hub_parser.add_argument(
        "--subscription-dir", default="/var/lib/etxr/subscriptions"
    )
    hub_parser.add_argument("--listen", default="127.0.0.1")
    hub_parser.add_argument("--port", type=int, default=18180)
    agent_parser = subparsers.add_parser("agent")
    agent_parser.add_argument("--state", required=True)
    agent_parser.add_argument("--etxr-bin", default="/usr/local/sbin/etxr")
    agent_parser.add_argument(
        "--usage-file", default="/var/lib/etxr/usage.json"
    )
    agent_parser.add_argument(
        "--domain-file", default="/var/lib/etxr/domains.json"
    )
    args = parser.parse_args()
    if args.mode == "hub":
        hub = Hub(
            args.state,
            args.control_dir,
            args.etxr_bin,
            args.subscription_dir,
        )
        web.run_app(hub.app(), host=args.listen, port=args.port, access_log=None)
    else:
        asyncio.run(Agent(
            args.state, args.etxr_bin, args.usage_file, args.domain_file
        ).run())


if __name__ == "__main__":
    main()
PY
  # ETXR_CONTROL_HELPER_END
  mkdir -p "$(dirname "$CONTROL_HELPER")"
  install -m 755 "$tmp" "$CONTROL_HELPER"
  rm -f "$tmp"
}

ensure_control_runtime() {
  need_root
  if ! python3 -c 'import aiohttp' >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y python3 python3-aiohttp
  fi
  install_control_helper
  python3 -m py_compile "$CONTROL_HELPER"
}

write_systemd_units() {
  local xray_after="network-online.target" xray_wants="network-online.target"
  local xray_prestart=""
  if [[ "$(jq -r '.domain_audit.enabled // false' "$STATE_FILE")" == "true" ]]; then
    xray_after+=" etxr-domain-audit.service"
    xray_wants+=" etxr-domain-audit.service"
  fi
  if [[ "$(jq -r '.easytier.enabled // false' "$STATE_FILE")" == "true" ]]; then
    local et_ip
    xray_after+=" etxr-easytier.service"
    xray_wants+=" etxr-easytier.service"
    et_ip="$(jq -r '.easytier.ipv4' "$STATE_FILE")"
    valid_ipv4 "$et_ip" || die "Invalid EasyTier IPv4 in state"
    local wait_helper wait_helper_tmp
    wait_helper="$WAIT_IP_HELPER"
    wait_helper_tmp="$(mktemp)"
    cat >"$wait_helper_tmp" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
ip_addr="${1:-}"
[[ "$ip_addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 2
for _ in $(seq 1 30); do
  ip -4 address show | grep -Fq "inet ${ip_addr}/" && exit 0
  sleep 1
done
exit 1
EOF
    run install -D -m 755 "$wait_helper_tmp" "$wait_helper"
    rm -f "$wait_helper_tmp"
    xray_prestart="ExecStartPre=${wait_helper} ${et_ip}"
  fi
  if jq -e 'any(.users[]?;
    ((.speed_limit.up_mbps // 0) > 0) or
    ((.speed_limit.down_mbps // 0) > 0)
  )' "$STATE_FILE" >/dev/null; then
    xray_after+=" etxr-limiter.service"
    xray_wants+=" etxr-limiter.service"
  fi
  mkdir -p "$SYSTEMD_UNIT_DIR"
  cat <<EOF | run tee "$SYSTEMD_UNIT_DIR/etxr-xray.service" >/dev/null
[Unit]
Description=ETXR Xray
After=${xray_after}
Wants=${xray_wants}

[Service]
Type=simple
User=root
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
${xray_prestart}
ExecStart=${XRAY_BIN} run -config $(jq -r '.xray.config_path' "$STATE_FILE")
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  cat <<EOF | run tee "$SYSTEMD_UNIT_DIR/etxr-sing-box.service" >/dev/null
[Unit]
Description=ETXR Hysteria2 (sing-box)
After=network-online.target etxr-xray.service
Wants=network-online.target etxr-xray.service

[Service]
Type=simple
User=root
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ExecStart=${SING_BOX_BIN} run -c $(jq -r '.hysteria2.config_path' "$STATE_FILE")
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  cat <<EOF | run tee "$SYSTEMD_UNIT_DIR/etxr-limiter.service" >/dev/null
[Unit]
Description=ETXR per-user TCP/UDP bandwidth limiter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
DynamicUser=yes
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
LoadCredential=limits.json:${LIMITER_CONFIG}
ExecStart=${DATAPLANE_BIN} limiter --config %d/limits.json
Restart=on-failure
RestartSec=2s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

  cat <<EOF | run tee "$SYSTEMD_UNIT_DIR/etxr-meter.service" >/dev/null
[Unit]
Description=ETXR per-user traffic meter
After=etxr-xray.service etxr-sing-box.service
Wants=etxr-xray.service

[Service]
Type=simple
User=root
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ReadWritePaths=$(dirname "$USAGE_FILE")
ExecStart=${DATAPLANE_BIN} meter --state ${STATE_FILE} --usage-file ${USAGE_FILE} --xray-bin ${XRAY_BIN} --interval 30
Restart=always
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

  cat <<EOF | run tee "$SYSTEMD_UNIT_DIR/etxr-domain-audit.service" >/dev/null
[Unit]
Description=ETXR per-user destination domain auditor
After=network-online.target
Wants=network-online.target
Before=etxr-xray.service

[Service]
Type=simple
User=root
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_UNIX
RuntimeDirectory=etxr
RuntimeDirectoryMode=0700
ReadWritePaths=-$(dirname "$DOMAIN_FILE") -$(dirname "$DOMAIN_SOCKET")
ExecStart=${DATAPLANE_BIN} auditor --state ${STATE_FILE} --domain-file ${DOMAIN_FILE} --socket ${DOMAIN_SOCKET} --flush-interval 5
Restart=always
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF

  if [[ "$(jq -r '.easytier.enabled // false' "$STATE_FILE")" == "true" ]]; then
    local et_ip et_name et_secret et_peer et_port et_hostname et_config_tmp
    et_ip="$(jq -r '.easytier.ipv4' "$STATE_FILE")"
    et_name="$(jq -r '.easytier.network_name' "$STATE_FILE")"
    et_secret="$(jq -r '.easytier.network_secret' "$STATE_FILE")"
    et_peer="$(jq -r '.easytier.peer // ""' "$STATE_FILE")"
    et_port="$(jq -r '.easytier.tcp_port // 11010' "$STATE_FILE")"
    et_hostname="$(jq -r '.node.name' "$STATE_FILE")"
    valid_ipv4 "$et_ip" || die "Invalid EasyTier IPv4 in state"
    valid_secret_value "$et_name" || die "Invalid EasyTier network name in state"
    valid_secret_value "$et_secret" || die "Invalid EasyTier network secret in state"
    valid_port "$et_port" || die "Invalid EasyTier TCP port in state"
    valid_absolute_path "$EASYTIER_CONFIG" || die "Invalid EasyTier config path"
    [[ -z "$et_peer" || "$et_peer" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] ||
      die "Invalid EasyTier peer in state"
    et_config_tmp="$(mktemp)"
    {
      printf 'ipv4 = "%s"\n' "$et_ip"
      printf 'hostname = "%s"\n' "$et_hostname"
      if [[ -n "$et_peer" ]]; then
        printf 'listeners = []\n'
        printf '\n[[peer]]\n'
        printf 'uri = "tcp://%s"\n' "$et_peer"
      else
        printf 'listeners = ["tcp://0.0.0.0:%s"]\n' "$et_port"
      fi
      printf '\n[network_identity]\n'
      printf 'network_name = "%s"\n' "$et_name"
      printf 'network_secret = "%s"\n' "$et_secret"
      printf '\n[flags]\n'
      printf 'private_mode = true\n'
      printf 'enable_ipv6 = false\n'
      printf 'enable_encryption = true\n'
      printf 'encryption_algorithm = "aes-gcm"\n'
    } >"$et_config_tmp"
    chmod 600 "$et_config_tmp"
    if [[ -x "$EASYTIER_CORE_BIN" ]]; then
      "$EASYTIER_CORE_BIN" --check-config --config-file "$et_config_tmp" || {
        rm -f "$et_config_tmp"
        die "EasyTier 配置检查失败"
      }
    fi
    ensure_parent "$EASYTIER_CONFIG"
    run install -m 600 "$et_config_tmp" "$EASYTIER_CONFIG"
    rm -f "$et_config_tmp"
    cat <<EOF | run tee "$SYSTEMD_UNIT_DIR/etxr-easytier.service" >/dev/null
[Unit]
Description=ETXR EasyTier
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ExecStart=${EASYTIER_CORE_BIN} --config-file ${EASYTIER_CONFIG} --console-log-level warn
Restart=always
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  fi

  if [[ "$(jq -r '.control.enabled // false' "$STATE_FILE")" == "true" ]]; then
    cat <<EOF | run tee "$SYSTEMD_UNIT_DIR/etxr-control.service" >/dev/null
[Unit]
Description=ETXR WSS Control Hub
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ExecStart=/usr/bin/python3 ${CONTROL_HELPER} hub --state ${STATE_FILE} --control-dir ${CONTROL_DIR} --etxr-bin ${SELF_BIN} --subscription-dir ${SUBSCRIPTION_DIR} --listen 127.0.0.1 --port $(jq -r '.control.port' "$STATE_FILE")
Restart=always
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
  fi

  if [[ "$(jq -r '.control.agent.enabled // false' "$STATE_FILE")" == "true" ]]; then
    cat <<EOF | run tee "$SYSTEMD_UNIT_DIR/etxr-agent.service" >/dev/null
[Unit]
Description=ETXR WSS Configuration Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
    ExecStart=/usr/bin/python3 ${CONTROL_HELPER} agent --state ${STATE_FILE} --etxr-bin /usr/local/sbin/etxr --usage-file ${USAGE_FILE} --domain-file ${DOMAIN_FILE}
Restart=always
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
  fi
}

configure_ufw_from_state() {
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q '^Status: active' || return 0
  local role port source
  local ufw_state="${RUNTIME_DIR}/ufw-rules.tsv"
  if [[ -f "$ufw_state" ]]; then
    while IFS=$'\t' read -r port source; do
      [[ -n "$port" ]] || continue
      if [[ "$source" == "udp" ]]; then
        ufw delete allow "${port}/udp" >/dev/null 2>&1 || true
      elif [[ "$source" == "tcp" ]]; then
        ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
      else
        ufw delete allow from "${source%/32}" to any port "$port" proto tcp \
          >/dev/null 2>&1 || true
      fi
    done <"$ufw_state"
  fi
  ensure_parent "$ufw_state"
  : >"$ufw_state"
  ufw_add_tcp() {
    local add_port="$1" add_source="${2:-}"
    if [[ -n "$add_source" ]]; then
      ufw allow from "${add_source%/32}" to any port "$add_port" proto tcp >/dev/null
      printf '%s\t%s\n' "$add_port" "$add_source" >>"$ufw_state"
    else
      ufw allow "${add_port}/tcp" >/dev/null
      printf '%s\ttcp\n' "$add_port" >>"$ufw_state"
    fi
  }
  ufw_add_udp() {
    local add_port="$1"
    ufw allow "${add_port}/udp" >/dev/null
    printf '%s\tudp\n' "$add_port" >>"$ufw_state"
  }
  role="$(jq -r '.node.role' "$STATE_FILE")"
  if [[ "$(jq -r '.easytier.enabled // false' "$STATE_FILE")" == "true" &&
        ( "$role" == "gateway" || "$role" == "hybrid" ) ]]; then
    port="$(jq -r '.easytier.tcp_port // 11010' "$STATE_FILE")"
    ufw_add_tcp "$port"
  fi
  while IFS=$'\t' read -r port source; do
    [[ -n "$port" ]] || continue
    if [[ -n "$source" ]]; then
      ufw_add_tcp "$port" "$source"
    else
      ufw_add_tcp "$port"
    fi
  done < <(jq -r '.xray.relay_inbounds[]? |
    select(.public == true) | [.port, (.allowed_source // "")] | @tsv' "$STATE_FILE")
  while IFS= read -r port; do
    [[ -n "$port" ]] || continue
    ufw_add_tcp "$port"
  done < <(jq -r '
    .xray.reality_inbounds[]? |
    if (.listen // "0.0.0.0") == "127.0.0.1" then empty
    else .port end
  ' "$STATE_FILE")
  while IFS= read -r port; do
    [[ -n "$port" ]] || continue
    ufw_add_tcp "$port"
  done < <(jq -r '
    .xray.routes[]? |
    select(
      .direct == true and
      (.listen // "0.0.0.0") != "127.0.0.1"
    ) | .port
  ' "$STATE_FILE")
  if [[ "$(jq -r '.hysteria2.enabled' "$STATE_FILE")" == "true" ]]; then
    port="$(jq -r '.hysteria2.port' "$STATE_FILE")"
    ufw_add_udp "$port"
  fi
}

check_standalone_nginx_takeover() {
  [[ "$(jq -r '.nginx.mode' "$STATE_FILE")" == "standalone" ]] || return 0
  local target stream_target candidate hits=""
  target="$(jq -r '.nginx.standalone_path' "$STATE_FILE")"
  stream_target="$(jq -r '.nginx.stream_path // empty' "$STATE_FILE")"
  while IFS= read -r -d '' candidate; do
    [[ "$candidate" != "$target" && "$candidate" != "$stream_target" ]] || continue
    nginx_tcp443_file_has_active "$candidate" &&
      hits+="${candidate}"$'\n'
  done < <(nginx_config_candidates)
  if [[ -n "$hits" && "$FORCE" -ne 1 ]]; then
    printf '%s' "$hits" >&2
    die "标准 nginx 中已有其他 TCP 443 站点；请改用宝塔复用模式或先处理冲突"
  fi
}

cmd_apply() {
  need_root
  require_state
  state_lock_acquire
  cmd_render --out "$GENERATED_DIR" ||
    die "配置生成失败，已停止应用"
  validate_state_semantics ||
    die "状态语义检查失败，已停止应用"
  check_standalone_nginx_takeover ||
    die "nginx 接管检查失败，已停止应用"

  local xray_config sing_config mode nginx_target nginx_paths_target="" nb=""
  local nginx_stream_target="" nginx_previous="" nginx_paths_previous=""
  local nginx_stream_loader_target=""
  local rollback_dir="" rollback_service quic_manifest="" tcp443_manifest=""
  local hy2_enabled hy2_port hy2_shared_udp443 domain_audit_enabled
  local nginx_was_running=0
  local nginx_should_reload=0 nginx_quic_backup="" nginx_tcp443_backup=""
  local auto_rebind_https https_listen_port post_quic_manifest=""
  xray_config="$(jq -r '.xray.config_path' "$STATE_FILE")"
  sing_config="$(jq -r '.hysteria2.config_path' "$STATE_FILE")"
  mode="$(jq -r '.nginx.mode' "$STATE_FILE")"
  hy2_enabled="$(jq -r '.hysteria2.enabled // false' "$STATE_FILE")"
  hy2_port="$(jq -r '.hysteria2.port // 8443' "$STATE_FILE")"
  hy2_shared_udp443="$(jq -r '.hysteria2.shared_udp443 // false' "$STATE_FILE")"
  domain_audit_enabled="$(jq -r '.domain_audit.enabled // false' "$STATE_FILE")"
  auto_rebind_https="$(jq -r '.nginx.auto_rebind_https // false' "$STATE_FILE")"
  https_listen_port="$(jq -r '.nginx.https_listen_port // 8443' "$STATE_FILE")"
  quic_manifest="$(mktemp)"
  tcp443_manifest="$(mktemp)"
  if [[ "$hy2_shared_udp443" == "true" ]]; then
    nginx_quic_active_manifest "$quic_manifest"
    if port_is_listening udp "$hy2_port" &&
       ! port_is_nginx_owned udp "$hy2_port" &&
       ! port_is_sing_box_owned udp "$hy2_port"; then
      rm -f "$quic_manifest"
      die "UDP $hy2_port 已被其他程序占用，未修改 nginx"
    fi
    if port_is_nginx_owned udp "$hy2_port" && [[ ! -s "$quic_manifest" ]]; then
      rm -f "$quic_manifest"
      die "nginx 正在占用 UDP $hy2_port，但没有在受支持的配置目录中找到 H3/QUIC 配置"
    fi
  else
    : >"$quic_manifest"
  fi
  if [[ "$auto_rebind_https" == "true" ]]; then
    nginx_tcp443_active_manifest "$tcp443_manifest"
    if [[ ! -s "$tcp443_manifest" ]]; then
      rm -f "$quic_manifest" "$tcp443_manifest"
      die "没有找到需要迁移到内部 HTTPS 端口的宝塔 TCP 443 vhost"
    fi
  else
    : >"$tcp443_manifest"
  fi
  if [[ "$(jq -r '.nginx.shared_tcp443 // false' "$STATE_FILE")" == "true" ]]; then
    nginx_stream_target="$(jq -r '.nginx.stream_path' "$STATE_FILE")"
    if [[ "$mode" == "standalone" ]]; then
      nginx_stream_loader_target="$(jq -r '.nginx.stream_loader_path' "$STATE_FILE")"
    fi
  fi
  nginx_process_running && nginx_was_running=1

  if (( ! DRY_RUN )); then
    rollback_dir="$(mktemp -d "$RUNTIME_DIR/.apply.XXXXXX")"
    [[ ! -e "$xray_config" ]] || cp -a "$xray_config" "$rollback_dir/xray"
    [[ ! -e "$sing_config" ]] || cp -a "$sing_config" "$rollback_dir/sing-box"
    [[ ! -e "$LIMITER_CONFIG" ]] ||
      cp -a "$LIMITER_CONFIG" "$rollback_dir/limits.json"
    [[ ! -e "$EASYTIER_CONFIG" ]] ||
      cp -a "$EASYTIER_CONFIG" "$rollback_dir/easytier.toml"
    if [[ -n "$nginx_stream_target" ]]; then
      [[ ! -e "$nginx_stream_target" ]] ||
        cp -a "$nginx_stream_target" "$rollback_dir/nginx-stream"
    fi
    if [[ -n "$nginx_stream_loader_target" ]]; then
      [[ ! -e "$nginx_stream_loader_target" ]] ||
        cp -a "$nginx_stream_loader_target" "$rollback_dir/nginx-stream-loader"
    fi
    if [[ -d "$SUBSCRIPTION_DIR" ]]; then
      : >"$rollback_dir/subscriptions.existed"
      cp -a "$SUBSCRIPTION_DIR" "$rollback_dir/subscriptions"
    fi
    for rollback_service in etxr-easytier etxr-limiter etxr-domain-audit etxr-xray etxr-sing-box etxr-meter etxr-control etxr-agent; do
      if systemctl is-active --quiet "${rollback_service}.service" 2>/dev/null; then
        : >"$rollback_dir/${rollback_service}.active"
      fi
      if systemctl is-enabled --quiet "${rollback_service}.service" 2>/dev/null; then
        : >"$rollback_dir/${rollback_service}.enabled"
      fi
      if [[ -e "$SYSTEMD_UNIT_DIR/${rollback_service}.service" ]]; then
        cp -a "$SYSTEMD_UNIT_DIR/${rollback_service}.service" \
          "$rollback_dir/${rollback_service}.unit"
      fi
    done
  fi

  rollback_apply() {
    (( DRY_RUN )) && return 0
    if [[ -e "$rollback_dir/xray" ]]; then
      rm -f "$xray_config"
      cp -a "$rollback_dir/xray" "$xray_config"
    else
      rm -f "$xray_config"
    fi
    if [[ -e "$rollback_dir/sing-box" ]]; then
      rm -f "$sing_config"
      cp -a "$rollback_dir/sing-box" "$sing_config"
    else
      rm -f "$sing_config"
    fi
    if [[ -e "$rollback_dir/limits.json" ]]; then
      rm -f "$LIMITER_CONFIG"
      cp -a "$rollback_dir/limits.json" "$LIMITER_CONFIG"
    else
      rm -f "$LIMITER_CONFIG"
    fi
    if [[ -e "$rollback_dir/easytier.toml" ]]; then
      rm -f "$EASYTIER_CONFIG"
      cp -a "$rollback_dir/easytier.toml" "$EASYTIER_CONFIG"
    else
      rm -f "$EASYTIER_CONFIG"
    fi
    rm -rf "$SUBSCRIPTION_DIR"
    if [[ -f "$rollback_dir/subscriptions.existed" &&
          -d "$rollback_dir/subscriptions" ]]; then
      cp -a "$rollback_dir/subscriptions" "$SUBSCRIPTION_DIR"
    fi
    if [[ -n "$nginx_target" ]]; then
      if [[ -n "$nginx_previous" ]]; then
        cp -a "$nginx_previous" "$nginx_target"
      else
        rm -f "$nginx_target"
      fi
    fi
    if [[ -n "$nginx_paths_target" ]]; then
      if [[ -n "$nginx_paths_previous" ]]; then
        cp -a "$nginx_paths_previous" "$nginx_paths_target"
      else
        rm -f "$nginx_paths_target"
      fi
    fi
    if [[ -n "$nginx_stream_target" ]]; then
      if [[ -e "$rollback_dir/nginx-stream" ]]; then
        cp -a "$rollback_dir/nginx-stream" "$nginx_stream_target"
      else
        rm -f "$nginx_stream_target"
      fi
    fi
    if [[ -n "$nginx_stream_loader_target" ]]; then
      if [[ -e "$rollback_dir/nginx-stream-loader" ]]; then
        cp -a "$rollback_dir/nginx-stream-loader" "$nginx_stream_loader_target"
      else
        rm -f "$nginx_stream_loader_target"
      fi
    fi
    if [[ -n "$nginx_quic_backup" ]]; then
      nginx_quic_restore_backup "$nginx_quic_backup" || true
    fi
    if [[ -n "$nginx_tcp443_backup" ]]; then
      nginx_tcp443_restore_backup "$nginx_tcp443_backup" || true
    fi
    systemctl daemon-reload 2>/dev/null || true
    for rollback_service in etxr-easytier etxr-limiter etxr-domain-audit etxr-xray etxr-sing-box etxr-meter etxr-control etxr-agent; do
      if [[ -f "$rollback_dir/${rollback_service}.unit" ]]; then
        cp -a "$rollback_dir/${rollback_service}.unit" \
          "$SYSTEMD_UNIT_DIR/${rollback_service}.service"
      else
        rm -f "$SYSTEMD_UNIT_DIR/${rollback_service}.service"
      fi
    done
    systemctl daemon-reload 2>/dev/null || true
    for rollback_service in etxr-easytier etxr-limiter etxr-domain-audit etxr-xray etxr-sing-box etxr-meter etxr-control etxr-agent; do
      if [[ -f "$rollback_dir/${rollback_service}.enabled" ]]; then
        systemctl enable "${rollback_service}.service" 2>/dev/null || true
      else
        systemctl disable "${rollback_service}.service" 2>/dev/null || true
      fi
      if [[ -f "$rollback_dir/${rollback_service}.active" ]]; then
        systemctl restart "${rollback_service}.service" 2>/dev/null || true
      else
        systemctl stop "${rollback_service}.service" 2>/dev/null || true
      fi
    done
    if [[ -n "${nb:-}" ]] &&
       { (( nginx_was_running )) || [[ "$mode" != "disabled" ]]; }; then
      if "$nb" -t >/dev/null 2>&1; then
        "$nb" -s reload >/dev/null 2>&1 || true
      fi
    fi
    rm -rf "$rollback_dir"
    rollback_dir=""
  }

  [[ -x "$XRAY_BIN" ]] || die "Install Xray before apply"
  "$XRAY_BIN" run -test -config "$GENERATED_DIR/xray.json" ||
    die "Xray 配置检查失败，未写入 live 配置"
  if [[ "$hy2_enabled" == "true" ]]; then
    [[ -x "$SING_BOX_BIN" ]] || die "Install sing-box before enabling Hysteria2"
    "$SING_BOX_BIN" check -c "$GENERATED_DIR/sing-box.json" ||
      die "sing-box 配置检查失败，未写入 live 配置"
  fi
  if (( ! DRY_RUN )); then
    install_data_helper
  fi
  if [[ "$(jq -r '(.control.enabled // false) or (.control.agent.enabled // false)' "$STATE_FILE")" == "true" ]] &&
     (( ! DRY_RUN )); then
    ensure_control_runtime
  fi
  if [[ "$mode" != "disabled" || -s "$quic_manifest" ||
        ( "$hy2_shared_udp443" == "true" && "$nginx_was_running" -eq 1 ) ]]; then
    nb="$(nginx_bin)" || die "nginx not found"
    if [[ "$mode" != "disabled" &&
          "$(jq -r '.nginx.shared_tcp443 // false' "$STATE_FILE")" == "true" ]]; then
      check_baota_shared_nginx_layout "$nb"
    fi
    "$nb" -t || die "现有 nginx 配置检查失败，已停止应用"
  fi

  cmd_backup
  ensure_parent "$xray_config"
  if [[ "$GENERATED_DIR/xray.json" != "$xray_config" ]]; then
    run install -m 600 "$GENERATED_DIR/xray.json" "$xray_config" ||
      { rollback_apply; die "写入 Xray live 配置失败"; }
  fi

  if [[ "$hy2_enabled" == "true" ]]; then
    ensure_parent "$sing_config"
    if [[ "$GENERATED_DIR/sing-box.json" != "$sing_config" ]]; then
      run install -m 600 "$GENERATED_DIR/sing-box.json" "$sing_config" ||
        { rollback_apply; die "写入 sing-box live 配置失败"; }
    fi
  fi
  ensure_parent "$LIMITER_CONFIG"
  if [[ "$GENERATED_DIR/limits.json" != "$LIMITER_CONFIG" ]]; then
    run install -m 600 "$GENERATED_DIR/limits.json" "$LIMITER_CONFIG" ||
      { rollback_apply; die "写入单用户限速配置失败"; }
  fi

  if [[ "$mode" == "disabled" ]]; then
    nginx_target=""
  elif [[ "$mode" == "snippet" ]]; then
    nginx_target="$(jq -r '.nginx.snippet_path' "$STATE_FILE")"
    [[ -n "$nginx_target" ]] || die "nginx.snippet_path is empty"
    ensure_parent "$nginx_target"
  else
    nginx_target="$(jq -r '.nginx.standalone_path' "$STATE_FILE")"
    nginx_paths_target="$(jq -r '.nginx.paths_path // "/etc/etxr/live/nginx-paths.conf"' "$STATE_FILE")"
    ensure_parent "$nginx_target"
    ensure_parent "$nginx_paths_target"
  fi
  if [[ "$(jq -r '.nginx.shared_tcp443 // false' "$STATE_FILE")" == "true" ]]; then
    [[ -n "$nginx_stream_target" ]] || die "nginx.stream_path is empty"
    ensure_parent "$nginx_stream_target"
    if [[ "$mode" == "standalone" ]]; then
      [[ -n "$nginx_stream_loader_target" ]] ||
        die "nginx.stream_loader_path is empty"
      ensure_parent "$nginx_stream_loader_target"
    fi
  fi

  if [[ -n "$nginx_target" && -e "$nginx_target" ]]; then
    nginx_previous="$(mktemp)"
    cp -a "$nginx_target" "$nginx_previous"
  fi
  if [[ -n "$nginx_paths_target" && -e "$nginx_paths_target" ]]; then
    nginx_paths_previous="$(mktemp)"
    cp -a "$nginx_paths_target" "$nginx_paths_previous"
  fi
  if [[ "$mode" == "disabled" ]]; then
    :
  elif [[ "$mode" == "snippet" ]]; then
    run install -m 600 "$GENERATED_DIR/nginx-paths.conf" "$nginx_target" ||
      { rollback_apply; die "写入宝塔 nginx extension 配置失败"; }
  else
    run install -m 600 "$GENERATED_DIR/nginx-paths.conf" "$nginx_paths_target" ||
      { rollback_apply; die "写入 nginx Path 配置失败"; }
    run install -m 600 "$GENERATED_DIR/nginx-standalone.conf" "$nginx_target" ||
      { rollback_apply; die "写入 nginx 站点配置失败"; }
  fi
  if [[ -n "$nginx_stream_target" ]]; then
    run install -m 600 "$GENERATED_DIR/nginx-stream.conf" "$nginx_stream_target" ||
      { rollback_apply; die "写入 nginx stream 配置失败"; }
  fi
  if [[ -n "$nginx_stream_loader_target" ]]; then
    run install -m 600 "$GENERATED_DIR/nginx-stream-loader.conf" \
      "$nginx_stream_loader_target" ||
      { rollback_apply; die "写入 nginx stream 加载配置失败"; }
  fi

  if [[ "$auto_rebind_https" == "true" && -s "$tcp443_manifest" ]]; then
    if (( DRY_RUN )); then
      while IFS= read -r -d '' rollback_service; do
        log "Would move Baota TCP 443 listener to 127.0.0.1:${https_listen_port} in $rollback_service"
      done <"$tcp443_manifest"
    else
      nginx_tcp443_backup="$rollback_dir/nginx-tcp443"
      if ! nginx_tcp443_rebind_manifest "$tcp443_manifest" \
        "$nginx_tcp443_backup" "$https_listen_port"; then
        rollback_apply
        die "迁移宝塔 HTTPS 到内部端口失败，已恢复原配置"
      fi
      if [[ -n "$LAST_BACKUP_DIR" ]]; then
        cp -a "$nginx_tcp443_backup" "$LAST_BACKUP_DIR/nginx-tcp443" || {
          rollback_apply
          die "保存宝塔 TCP 443 持久备份失败，已恢复原配置"
        }
      fi
      if (( NGINX_TCP443_CHANGED )); then
        nginx_should_reload=1
        log "已把宝塔 HTTPS 移到 127.0.0.1:${https_listen_port}，TCP 443 交给 SNI 分流"
      fi
    fi
  fi

  if [[ "$hy2_shared_udp443" == "true" && -s "$quic_manifest" ]]; then
    if (( DRY_RUN )); then
      while IFS= read -r -d '' rollback_service; do
        log "Would disable nginx H3/QUIC in $rollback_service"
      done <"$quic_manifest"
    else
      nginx_quic_backup="$rollback_dir/nginx-quic"
      if ! nginx_quic_disable_manifest "$quic_manifest" "$nginx_quic_backup"; then
        rollback_apply
        die "关闭 nginx H3/QUIC 失败，已恢复原配置"
      fi
      if [[ -n "$LAST_BACKUP_DIR" ]]; then
        cp -a "$nginx_quic_backup" "$LAST_BACKUP_DIR/nginx-quic" || {
          rollback_apply
          die "保存 nginx H3/QUIC 持久备份失败，已恢复原配置"
        }
      fi
      if (( NGINX_QUIC_CHANGED )); then
        nginx_should_reload=1
        log "已关闭 nginx H3/QUIC；普通 HTTPS、HTTP/2 和 TCP 443 保持不变"
      fi
    fi
  fi
  [[ "$mode" == "disabled" ]] || nginx_should_reload=1

  mkdir -p "$SUBSCRIPTION_DIR"
  [[ -n "$SUBSCRIPTION_DIR" && "$SUBSCRIPTION_DIR" != "/" ]] ||
    { rollback_apply; die "Unsafe subscription directory"; }
  if (( ! DRY_RUN )); then
    find "$SUBSCRIPTION_DIR" -mindepth 1 -maxdepth 1 -type f -delete
  fi
  run cp -a "$GENERATED_DIR/subscriptions/." "$SUBSCRIPTION_DIR/"
  # Keep subscription contents private while allowing the nginx worker group
  # to traverse and read the token-named files.
  local subscription_group=www-data
  getent passwd www >/dev/null 2>&1 && subscription_group=www
  run chown root:"$subscription_group" "$(dirname "$SUBSCRIPTION_DIR")" "$SUBSCRIPTION_DIR" ||
    { rollback_apply; die "设置订阅目录属主失败"; }
  run chmod 751 "$(dirname "$SUBSCRIPTION_DIR")"
  run chmod 750 "$SUBSCRIPTION_DIR" ||
    { rollback_apply; die "设置订阅目录权限失败"; }
  if (( ! DRY_RUN )); then
    find "$SUBSCRIPTION_DIR" -mindepth 1 -maxdepth 1 -type f \
      -exec chown root:"$subscription_group" {} + \
      -exec chmod 640 {} + || { rollback_apply; die "设置订阅文件权限失败"; }
  fi
  write_systemd_units || { rollback_apply; die "写入 systemd 服务失败"; }

  if (( ! DRY_RUN )); then
    if [[ -n "$nb" ]] && ! "$nb" -t; then
      warn "New nginx configuration is invalid; rolling back"
      rollback_apply
      "$nb" -t || true
      die "nginx validation failed; previous configuration restored"
    fi
    systemctl daemon-reload ||
      { rollback_apply; die "systemd 配置重载失败"; }
    configure_ufw_from_state ||
      { rollback_apply; die "防火墙规则应用失败"; }
    if (( nginx_should_reload )) &&
       { (( nginx_was_running )) || [[ "$mode" != "disabled" ]]; }; then
      "$nb" -s reload ||
        { rollback_apply; die "nginx reload 失败，已恢复 H3/QUIC 和其他配置"; }
      if [[ "$hy2_shared_udp443" == "true" ]]; then
        post_quic_manifest="$(mktemp)"
        nginx_quic_active_manifest "$post_quic_manifest"
        if [[ -s "$post_quic_manifest" ]]; then
          while IFS= read -r -d '' rollback_service; do
            warn "nginx 实际加载配置中仍有 H3/QUIC：$rollback_service"
          done <"$post_quic_manifest"
          rm -f "$post_quic_manifest"
          post_quic_manifest=""
          rollback_apply
          die "nginx reload 后仍有 H3/QUIC 配置，已恢复原配置"
        fi
        rm -f "$post_quic_manifest"
        post_quic_manifest=""
        if port_is_nginx_owned udp "$hy2_port"; then
          log "正在等待旧 nginx worker 释放 UDP $hy2_port（最多 30 秒）"
        fi
        if ! wait_for_nginx_udp_release "$hy2_port" 30; then
          rollback_apply
          die "等待 30 秒后 nginx 仍占用 UDP $hy2_port，已恢复原配置"
        fi
      fi
    fi
    if [[ "$(jq -r '.easytier.enabled // false' "$STATE_FILE")" == "true" ]]; then
      [[ -x "$EASYTIER_CORE_BIN" ]] ||
        { rollback_apply; die "Install EasyTier before apply"; }
    fi
    if [[ "$(jq -r '.easytier.enabled // false' "$STATE_FILE")" == "true" ]]; then
      systemctl enable --now etxr-easytier.service ||
        { rollback_apply; die "EasyTier 服务启动失败"; }
      systemctl restart etxr-easytier.service ||
        { rollback_apply; die "EasyTier 服务重启失败"; }
      local et_ip wait_count
      et_ip="$(jq -r '.easytier.ipv4' "$STATE_FILE")"
      for ((wait_count=1; wait_count<=20; wait_count++)); do
        ip address show 2>/dev/null | grep -qF "$et_ip" && break
        sleep 1
      done
    fi
    local limited_users_count
    limited_users_count="$(jq '[
      .users[] |
      select(
        .enabled == true and
        (((.speed_limit.up_mbps // 0) > 0) or
         ((.speed_limit.down_mbps // 0) > 0))
      )
    ] | length' "$STATE_FILE")" ||
      { rollback_apply; die "读取单用户限速状态失败"; }
    if (( limited_users_count > 0 )); then
      systemctl enable --now etxr-limiter.service ||
        { rollback_apply; die "单用户限速服务启动失败"; }
      systemctl restart etxr-limiter.service ||
        { rollback_apply; die "单用户限速服务重启失败"; }
    else
      systemctl disable --now etxr-limiter.service 2>/dev/null || true
    fi
    if [[ "$domain_audit_enabled" == "true" ]]; then
      mkdir -p "$(dirname "$DOMAIN_FILE")" ||
        { rollback_apply; die "创建用户域名统计数据目录失败"; }
      install -d -m 700 "$(dirname "$DOMAIN_SOCKET")" ||
        { rollback_apply; die "创建用户域名统计目录失败"; }
      systemctl enable --now etxr-domain-audit.service ||
        { rollback_apply; die "用户域名统计服务启动失败"; }
      systemctl restart etxr-domain-audit.service ||
        { rollback_apply; die "用户域名统计服务重启失败"; }
    else
      systemctl disable --now etxr-domain-audit.service 2>/dev/null || true
    fi
    systemctl enable --now etxr-xray.service ||
      { rollback_apply; die "Xray 服务启动失败"; }
    systemctl restart etxr-xray.service ||
      { rollback_apply; die "Xray 服务重启失败"; }

    if [[ "$hy2_enabled" == "true" ]]; then
      systemctl enable --now etxr-sing-box.service ||
        { rollback_apply; die "sing-box 服务启动失败"; }
      systemctl restart etxr-sing-box.service ||
        { rollback_apply; die "sing-box 服务重启失败"; }
      verify_hy2_udp_listener "$hy2_port" "$hy2_shared_udp443" ||
        { rollback_apply; die "Hysteria2 UDP 监听验证失败"; }
    else
      systemctl disable --now etxr-sing-box.service 2>/dev/null || true
    fi

    mkdir -p "$(dirname "$USAGE_FILE")" ||
      { rollback_apply; die "创建流量统计目录失败"; }
    systemctl enable --now etxr-meter.service ||
      { rollback_apply; die "单用户流量统计服务启动失败"; }
    systemctl restart etxr-meter.service ||
      { rollback_apply; die "单用户流量统计服务重启失败"; }

    if [[ "$(jq -r '.control.enabled // false' "$STATE_FILE")" == "true" ]]; then
      systemctl enable --now etxr-control.service ||
        { rollback_apply; die "WSS 控制服务启动失败"; }
      systemctl restart etxr-control.service ||
        { rollback_apply; die "WSS 控制服务重启失败"; }
    else
      systemctl disable --now etxr-control.service 2>/dev/null || true
    fi

    if [[ "$(jq -r '.control.agent.enabled // false' "$STATE_FILE")" == "true" ]]; then
      if [[ "${ETXR_AGENT_APPLY:-0}" != "1" ]]; then
        systemctl enable --now etxr-agent.service ||
          { rollback_apply; die "WSS 配置 Agent 启动失败"; }
        systemctl restart etxr-agent.service ||
          { rollback_apply; die "WSS 配置 Agent 重启失败"; }
      fi
    else
      systemctl disable --now etxr-agent.service 2>/dev/null || true
    fi

  fi
  rm -f "$quic_manifest" "$tcp443_manifest"
  [[ -z "$nginx_previous" ]] || rm -f "$nginx_previous"
  [[ -z "$nginx_paths_previous" ]] || rm -f "$nginx_paths_previous"
  [[ -z "$rollback_dir" ]] || rm -rf "$rollback_dir"
  state_lock_release
  log "Configuration applied"
}

detect_arch_xray() {
  case "$(uname -m)" in
    x86_64|amd64) echo 64 ;;
    aarch64|arm64) echo arm64-v8a ;;
    *) die "Unsupported Xray architecture: $(uname -m)" ;;
  esac
}

detect_arch_singbox() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) die "Unsupported sing-box architecture: $(uname -m)" ;;
  esac
}

detect_arch_easytier() {
  case "$(uname -m)" in
    x86_64|amd64) echo x86_64 ;;
    aarch64|arm64) echo aarch64 ;;
    *) die "Unsupported EasyTier architecture: $(uname -m)" ;;
  esac
}

detect_arch_dataplane() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) die "Unsupported ETXR data-plane architecture: $(uname -m)" ;;
  esac
}

archive_entry_safe() {
  local entry="$1"
  [[ -n "$entry" && "$entry" != /* && "$entry" != *\\* &&
     "$entry" != *".."* && "$entry" != *$'\n'* ]]
}

verify_zip_entries() {
  local archive="$1" entry
  while IFS= read -r entry; do
    archive_entry_safe "$entry" || die "Unsafe ZIP archive entry: $entry"
  done < <(unzip -Z1 "$archive")
}

verify_tar_entries() {
  local archive="$1" entry
  while IFS= read -r entry; do
    archive_entry_safe "$entry" || die "Unsafe TAR archive entry: $entry"
  done < <(tar -tzf "$archive")
  while IFS= read -r entry; do
    case "${entry:0:1}" in
      l|h) die "Unsafe TAR link entry: $entry" ;;
    esac
  done < <(LC_ALL=C tar -tvzf "$archive")
}

parse_xray_sha256_dgst() {
  local digest_file="$1"
  awk -F '=' '
    {
      key = toupper($1)
      gsub(/[[:space:]-]/, "", key)
      if (key == "SHA256" || key == "SHA2256") {
        digest = $2
        gsub(/[[:space:]]/, "", digest)
        print digest
        exit
      }
    }
  ' "$digest_file"
}

github_asset_sha256() {
  local api_json="$1" asset_name="$2" digest
  digest="$(jq -r --arg n "$asset_name" \
    '[.assets[] | select(.name == $n) | .digest][0] // empty' <<<"$api_json")"
  if [[ "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]]; then
    printf '%s\n' "${digest#sha256:}"
  fi
}

fetch_etxr_release_api() {
  need_cmd curl
  curl --proto '=https' --tlsv1.2 -fsSL \
    --connect-timeout 15 --max-time 120 --retry 3 --retry-delay 2 \
    "$ETXR_RELEASE_API"
}

etxr_release_version_from_api() {
  local api_json="$1" tag
  tag="$(jq -r '.tag_name // empty' <<<"$api_json")"
  [[ "$tag" =~ ^v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$ ]] ||
    die "GitHub 最新 ETXR Release 标签无效：${tag:-未找到}"
  printf '%s\n' "${tag#v}"
}

etxr_version_compare() {
  local left="$1" right="$2"
  local left_major left_minor left_patch right_major right_minor right_patch
  [[ "$left" =~ ^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$ ]] ||
    die "无效的 ETXR 版本号：$left"
  [[ "$right" =~ ^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$ ]] ||
    die "无效的 ETXR 版本号：$right"
  IFS=. read -r left_major left_minor left_patch <<<"$left"
  IFS=. read -r right_major right_minor right_patch <<<"$right"
  left_major=$((10#$left_major))
  left_minor=$((10#$left_minor))
  left_patch=$((10#$left_patch))
  right_major=$((10#$right_major))
  right_minor=$((10#$right_minor))
  right_patch=$((10#$right_patch))
  if (( left_major != right_major )); then
    (( left_major < right_major )) && printf '%s\n' -1 || printf '%s\n' 1
  elif (( left_minor != right_minor )); then
    (( left_minor < right_minor )) && printf '%s\n' -1 || printf '%s\n' 1
  elif (( left_patch != right_patch )); then
    (( left_patch < right_patch )) && printf '%s\n' -1 || printf '%s\n' 1
  else
    printf '%s\n' 0
  fi
}

etxr_latest_version() {
  local api
  need_jq
  api="$(fetch_etxr_release_api)"
  etxr_release_version_from_api "$api"
}

download_etxr_release_script() {
  local destination="$1" api version script_url checksums_url
  local expected api_expected checksums_api_expected actual checksums_actual
  need_cmd curl
  need_cmd sha256sum
  need_jq
  mkdir -p "$destination"
  api="$(fetch_etxr_release_api)"
  version="$(etxr_release_version_from_api "$api")"
  script_url="$(jq -r '[.assets[] | select(.name == "etxr.sh") | .browser_download_url][0] // empty' <<<"$api")"
  checksums_url="$(jq -r '[.assets[] | select(.name == "checksums.txt") | .browser_download_url][0] // empty' <<<"$api")"
  [[ "$script_url" == https://* ]] || die "ETXR Release 缺少 etxr.sh 下载地址"
  [[ "$checksums_url" == https://* ]] || die "ETXR Release 缺少 checksums.txt 下载地址"

  curl --proto '=https' --tlsv1.2 -fL --retry 3 --retry-delay 2 \
    "$checksums_url" -o "$destination/checksums.txt"
  curl --proto '=https' --tlsv1.2 -fL --retry 3 --retry-delay 2 \
    "$script_url" -o "$destination/etxr.sh"

  checksums_api_expected="$(github_asset_sha256 "$api" checksums.txt)"
  checksums_actual="$(sha256sum "$destination/checksums.txt" | awk '{print $1}')"
  [[ "$checksums_api_expected" =~ ^[0-9a-fA-F]{64}$ ]] ||
    die "GitHub Release API 没有提供 checksums.txt 的 SHA256"
  [[ "${checksums_api_expected,,}" == "${checksums_actual,,}" ]] ||
    die "ETXR checksums.txt 与 GitHub Release API 的 SHA256 不一致"
  expected="$(awk '$2 == "etxr.sh" || $2 == "*etxr.sh" {print $1; exit}' \
    "$destination/checksums.txt")"
  api_expected="$(github_asset_sha256 "$api" etxr.sh)"
  actual="$(sha256sum "$destination/etxr.sh" | awk '{print $1}')"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] ||
    die "ETXR checksums.txt 中没有 etxr.sh 的 SHA256"
  [[ "${expected,,}" == "${actual,,}" ]] || die "ETXR 脚本 SHA256 校验失败"
  [[ "$api_expected" =~ ^[0-9a-fA-F]{64}$ ]] ||
    die "GitHub Release API 没有提供 etxr.sh 的 SHA256"
  [[ "${api_expected,,}" == "${actual,,}" ]] ||
    die "ETXR 脚本与 GitHub Release API 的 SHA256 不一致"
  bash -n "$destination/etxr.sh" || die "下载的 ETXR 脚本语法检查失败"
  [[ "$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$destination/etxr.sh")" == "$version" ]] ||
    die "ETXR Release 标签与脚本版本不一致"
  printf '%s\n' "$version" >"$destination/VERSION"
}

download_etxr_pinned_script() {
  local destination="$1" version="${2:-$VERSION}" base
  local expected actual downloaded_version
  need_cmd curl
  need_cmd sha256sum
  [[ "$version" =~ ^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$ ]] ||
    die "无效的 ETXR 版本号：$version"
  mkdir -p "$destination"
  base="https://github.com/${ETXR_REPOSITORY}/releases/download/v${version}"
  curl --proto '=https' --tlsv1.2 -fL --retry 3 --retry-delay 2 \
    "$base/checksums.txt" -o "$destination/checksums.txt"
  curl --proto '=https' --tlsv1.2 -fL --retry 3 --retry-delay 2 \
    "$base/etxr.sh" -o "$destination/etxr.sh"
  expected="$(awk '$2 == "etxr.sh" || $2 == "*etxr.sh" {print $1; exit}' \
    "$destination/checksums.txt")"
  actual="$(sha256sum "$destination/etxr.sh" | awk '{print $1}')"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] ||
    die "ETXR checksums.txt 中没有 etxr.sh 的 SHA256"
  [[ "${expected,,}" == "${actual,,}" ]] || die "ETXR 脚本 SHA256 校验失败"
  bash -n "$destination/etxr.sh" || die "下载的 ETXR 脚本语法检查失败"
  downloaded_version="$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' \
    "$destination/etxr.sh" | head -n 1)"
  [[ "$downloaded_version" == "$version" ]] ||
    die "ETXR 下载版本与脚本版本不一致"
  chmod 755 "$destination/etxr.sh"
}

install_self_link() {
  [[ "$SELF_LINK" != "$SELF_BIN" ]] || return 0
  ensure_parent "$SELF_LINK"
  if [[ -e "$SELF_LINK" && ! -L "$SELF_LINK" ]]; then
    die "命令入口已被其他文件占用：$SELF_LINK"
  fi
  ln -sfn "$SELF_BIN" "$SELF_LINK"
}

install_self_command() {
  local source="${1:-${BASH_SOURCE[0]}}" download_dir="" target_dir temp
  if [[ ! -f "$source" || "$source" == /dev/fd/* ||
        "$source" == /proc/*/fd/* ]]; then
    download_dir="$(mktemp -d)"
    download_etxr_pinned_script "$download_dir" "$VERSION"
    source="$download_dir/etxr.sh"
  fi
  [[ -r "$source" ]] || die "ETXR 安装源不可读：$source"
  target_dir="$(dirname "$SELF_BIN")"
  mkdir -p "$target_dir"
  if [[ "$(readlink -f "$source")" != "$(readlink -f "$SELF_BIN" 2>/dev/null || true)" ]]; then
    temp="$(mktemp "$target_dir/.etxr.XXXXXX")"
    install -m 755 "$source" "$temp"
    bash -n "$temp" || {
      rm -f "$temp"
      die "准备安装的 ETXR 脚本语法检查失败"
    }
    [[ "$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$temp" | head -n 1)" == "$VERSION" ]] || {
      rm -f "$temp"
      die "准备安装的 ETXR 脚本版本不匹配"
    }
    mv -f "$temp" "$SELF_BIN"
  else
    chmod 755 "$SELF_BIN"
  fi
  install_self_link
  [[ "$($SELF_BIN version 2>/dev/null || true)" == "$VERSION" ]] ||
    die "安装后的 ETXR 命令执行检查失败：$SELF_BIN"
  [[ "$($SELF_LINK version 2>/dev/null || true)" == "$VERSION" ]] ||
    die "ETXR 命令入口执行检查失败：$SELF_LINK"
  [[ -z "$download_dir" ]] || rm -rf "$download_dir"
}

download_xray_release() {
  local destination="$1"
  local arch api version asset_name url dgst_url
  local expected="" sidecar_expected="" actual
  arch="$(detect_arch_xray)"
  api="$(curl --proto '=https' --tlsv1.2 -fsSL \
    https://api.github.com/repos/XTLS/Xray-core/releases/latest)"
  version="$(jq -r '.tag_name' <<<"$api")"
  asset_name="Xray-linux-${arch}.zip"
  url="$(jq -r --arg n "$asset_name" '.assets[] | select(.name == $n) | .browser_download_url' <<<"$api")"
  dgst_url="$(jq -r --arg n "${asset_name}.dgst" '.assets[] | select(.name == $n) | .browser_download_url' <<<"$api")"
  [[ -n "$url" && "$url" != "null" ]] || die "Xray release asset not found"
  mkdir -p "$destination"
  curl --proto '=https' --tlsv1.2 -fL "$url" -o "$destination/xray.zip"
  expected="$(github_asset_sha256 "$api" "$asset_name")"
  if [[ -n "$dgst_url" && "$dgst_url" != "null" ]]; then
    curl --proto '=https' --tlsv1.2 -fL "$dgst_url" -o "$destination/xray.zip.dgst"
    sidecar_expected="$(parse_xray_sha256_dgst "$destination/xray.zip.dgst")"
    if [[ "$sidecar_expected" =~ ^[0-9a-fA-F]{64}$ ]]; then
      if [[ -n "$expected" && "${expected,,}" != "${sidecar_expected,,}" ]]; then
        die "Xray release API 与 .dgst 的 SHA256 不一致"
      fi
      expected="$sidecar_expected"
    elif [[ -z "$expected" ]]; then
      die "Xray .dgst 中没有有效的 SHA2-256"
    else
      warn "Xray .dgst 格式无法识别，改用 GitHub release API 的 SHA256"
    fi
  fi
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] ||
    die "Xray release 没有可用的 SHA256 摘要"
  actual="$(sha256sum "$destination/xray.zip" | awk '{print $1}')"
  [[ "${expected,,}" == "${actual,,}" ]] ||
    die "Xray SHA256 校验失败"
  verify_zip_entries "$destination/xray.zip"
  mkdir -p "$destination/unpacked"
  unzip -q "$destination/xray.zip" -d "$destination/unpacked"
  find "$destination/unpacked" -type l -print -quit |
    grep -q . && die "Unsafe ZIP symlink entry"
  printf '%s\n' "$version" >"$destination/VERSION"
}

install_xray() {
  local tmp version
  tmp="$(mktemp -d)"
  download_xray_release "$tmp"
  version="$(cat "$tmp/VERSION")"
  install -m 755 "$tmp/unpacked/xray" "$XRAY_BIN"
  mkdir -p /usr/local/share/xray
  [[ ! -f "$tmp/unpacked/geoip.dat" ]] || install -m 644 "$tmp/unpacked/geoip.dat" /usr/local/share/xray/
  [[ ! -f "$tmp/unpacked/geosite.dat" ]] || install -m 644 "$tmp/unpacked/geosite.dat" /usr/local/share/xray/
  rm -rf "$tmp"
  log "Installed Xray $version"
}

install_sing_box() {
  local arch api version bare asset url checksums_url tmp
  local expected="" sidecar_expected="" actual
  arch="$(detect_arch_singbox)"
  api="$(curl --proto '=https' --tlsv1.2 -fsSL \
    https://api.github.com/repos/SagerNet/sing-box/releases/latest)"
  version="$(jq -r '.tag_name' <<<"$api")"
  bare="${version#v}"
  asset="sing-box-${bare}-linux-${arch}.tar.gz"
  url="$(jq -r --arg n "$asset" '.assets[] | select(.name == $n) | .browser_download_url' <<<"$api")"
  checksums_url="$(jq -r \
    '[.assets[] | select(.name | test("checksums.*txt$")) | .browser_download_url][0] // empty' \
    <<<"$api")"
  [[ -n "$url" && "$url" != "null" ]] || die "sing-box release asset not found"
  tmp="$(mktemp -d)"
  curl --proto '=https' --tlsv1.2 -fL "$url" -o "$tmp/$asset"
  expected="$(github_asset_sha256 "$api" "$asset")"
  if [[ -n "$checksums_url" && "$checksums_url" != "null" ]]; then
    curl --proto '=https' --tlsv1.2 -fL "$checksums_url" -o "$tmp/checksums.txt"
    sidecar_expected="$(awk -v n="$asset" '
      {
        file = $2
        sub(/^\*/, "", file)
        if (file == n) {
          print $1
          exit
        }
      }
    ' "$tmp/checksums.txt")"
    if [[ "$sidecar_expected" =~ ^[0-9a-fA-F]{64}$ ]]; then
      if [[ -n "$expected" && "${expected,,}" != "${sidecar_expected,,}" ]]; then
        die "sing-box release API 与校验文件的 SHA256 不一致"
      fi
      expected="$sidecar_expected"
    elif [[ -z "$expected" ]]; then
      die "sing-box 校验文件中没有当前安装包的 SHA256"
    else
      warn "sing-box 校验文件格式无法识别，改用 GitHub release API 的 SHA256"
    fi
  fi
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] ||
    die "sing-box release 没有可用的 SHA256 摘要"
  actual="$(sha256sum "$tmp/$asset" | awk '{print $1}')"
  [[ "${expected,,}" == "${actual,,}" ]] ||
    die "sing-box SHA256 校验失败"
  verify_tar_entries "$tmp/$asset"
  tar -xzf "$tmp/$asset" -C "$tmp"
  find "$tmp/sing-box-${bare}-linux-${arch}" -type l -print -quit |
    grep -q . && die "Unsafe TAR symlink entry"
  install -m 755 "$tmp/sing-box-${bare}-linux-${arch}/sing-box" "$SING_BOX_BIN"
  rm -rf "$tmp"
  log "Installed sing-box $version"
}

install_easytier() {
  local arch api version bare asset url digest expected actual tmp core cli
  arch="$(detect_arch_easytier)"
  api="$(curl --proto '=https' --tlsv1.2 -fsSL \
    https://api.github.com/repos/EasyTier/EasyTier/releases/latest)"
  version="$(jq -r '.tag_name' <<<"$api")"
  bare="${version#v}"
  asset="easytier-linux-${arch}-v${bare}.zip"
  url="$(jq -r --arg n "$asset" '.assets[] | select(.name == $n) | .browser_download_url' <<<"$api")"
  digest="$(jq -r --arg n "$asset" '.assets[] | select(.name == $n) | .digest // ""' <<<"$api")"
  [[ -n "$url" && "$url" != "null" ]] || die "EasyTier release asset not found"
  tmp="$(mktemp -d)"
  curl --proto '=https' --tlsv1.2 -fL "$url" -o "$tmp/easytier.zip"
  if [[ "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]]; then
    expected="${digest#sha256:}"
    actual="$(sha256sum "$tmp/easytier.zip" | awk '{print $1}')"
    [[ "${expected,,}" == "${actual,,}" ]] || die "EasyTier SHA256 mismatch"
  else
    die "EasyTier release 没有 SHA256 摘要"
  fi
  verify_zip_entries "$tmp/easytier.zip"
  unzip -q "$tmp/easytier.zip" -d "$tmp/unpacked"
  find "$tmp/unpacked" -type l -print -quit |
    grep -q . && die "Unsafe ZIP symlink entry"
  core="$(find "$tmp/unpacked" -type f -name easytier-core | head -n1)"
  cli="$(find "$tmp/unpacked" -type f -name easytier-cli | head -n1)"
  [[ -n "$core" && -n "$cli" ]] || die "EasyTier binaries not found in release"
  install -m 755 "$core" "$EASYTIER_CORE_BIN"
  install -m 755 "$cli" "$EASYTIER_CLI_BIN"
  rm -rf "$tmp"
  log "Installed EasyTier $version"
}

base_packages_ready() {
  local tool
  for tool in curl jq openssl unzip tar uuidgen python3 gzip base64 \
    sha256sum flock; do
    command -v "$tool" >/dev/null 2>&1 || return 1
  done
  [[ -s /etc/ssl/certs/ca-certificates.crt ]] || return 1
  python3 -c 'import aiohttp' >/dev/null 2>&1 || return 1
}

install_base_packages() {
  base_packages_ready && return 0
  need_root
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl jq openssl unzip tar uuid-runtime \
    python3 python3-aiohttp gzip coreutils util-linux
  base_packages_ready ||
    die "基础依赖安装完成后仍缺少 jq、openssl 或其他校验工具"
}

ensure_pair_join_tools() {
  base_packages_ready && return 0
  if (( DRY_RUN )); then
    log "Would install Pair ID validation tools: jq openssl gzip coreutils"
    return 0
  fi
  log "首次加入从服务器：正在安装 Pair ID 验签所需的基础工具"
  install_base_packages
}

cmd_install() {
  local components="xray,sing-box,easytier,dataplane,nginx"
  while (($#)); do
    case "$1" in
      --components) components="$2"; shift 2 ;;
      --help) echo "Usage: etxr install [--components xray,sing-box,easytier,dataplane,nginx]"; return ;;
      *) die "Unknown install option: $1" ;;
    esac
  done
  if (( DRY_RUN )); then
    log "Would install base packages: ca-certificates curl jq openssl unzip tar uuid-runtime python3 python3-aiohttp gzip coreutils util-linux"
    [[ ",$components," != *,nginx,* ]] ||
      log "Would install Debian nginx with stream preread module"
    [[ ",$components," != *,xray,* ]] || log "Would download and verify official latest Xray"
    [[ ",$components," != *,sing-box,* ]] || log "Would download and verify official latest sing-box"
    [[ ",$components," != *,easytier,* ]] || log "Would download and verify official latest EasyTier"
    [[ ",$components," != *,dataplane,* ]] || log "Would download and verify ETXR Go data plane ${VERSION}"
    log "Would install this script as $SELF_BIN"
    return
  fi
  need_root
  install_base_packages
  [[ ",$components," != *,nginx,* ]] ||
    apt-get install -y nginx libnginx-mod-stream
  [[ ",$components," != *,xray,* ]] || install_xray
  [[ ",$components," != *,sing-box,* ]] || install_sing_box
  [[ ",$components," != *,easytier,* ]] || install_easytier
  [[ ",$components," != *,dataplane,* ]] || install_data_helper
  install_self_command "${BASH_SOURCE[0]}"
  install_control_helper
  mkdir -p "$RUNTIME_DIR" "$GENERATED_DIR" "$BACKUP_DIR" "$SUBSCRIPTION_DIR"
  log "Installed etxr command: $SELF_LINK"
}

etxr_installed_version() {
  local installed
  if [[ ! -f "$SELF_BIN" ]]; then
    printf '未安装'
    return
  fi
  installed="$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$SELF_BIN" | head -n 1)"
  if [[ "$installed" =~ ^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$ ]]; then
    printf '%s' "$installed"
  else
    printf '未知'
  fi
}

cmd_self_status() {
  printf '当前正在运行的 ETXR：%s\n' "$VERSION"
  printf '服务器已安装的 ETXR：%s\n' "$(etxr_installed_version)"
  printf '脚本位置：%s\n' "$SELF_BIN"
  if [[ -x "$DATAPLANE_BIN" ]]; then
    printf 'Go 数据面版本：%s\n' "$($DATAPLANE_BIN version 2>/dev/null || printf '未知')"
  else
    printf 'Go 数据面版本：未安装\n'
  fi
}

cmd_self_check_update() {
  local latest comparison installed
  latest="$(etxr_latest_version)"
  installed="$(etxr_installed_version)"
  comparison="$(etxr_version_compare "$VERSION" "$latest")"
  cmd_self_status
  printf 'GitHub 最新 Release：%s\n' "$latest"
  if [[ "$comparison" == 0 && "$installed" == "$latest" ]]; then
    printf '%sETXR 已经是最新版本。%s\n' "$C_GREEN" "$C_RESET"
  elif [[ "$comparison" == 1 ]]; then
    printf '%s当前运行的是比 GitHub 正式版更新的开发版本，不会自动降级。%s\n' \
      "$C_YELLOW" "$C_RESET"
  else
    printf '%s发现 ETXR 新版本，可以执行一键更新。%s\n' "$C_YELLOW" "$C_RESET"
  fi
}

self_update_restore_file() {
  local backup="$1" target="$2"
  if [[ -e "$backup" ]]; then
    ensure_parent "$target"
    cp -a "$backup" "$target"
  else
    rm -f "$target"
  fi
}

restart_previously_active_etxr_services() {
  local manifest="$1" service
  command -v systemctl >/dev/null 2>&1 || return 0
  while IFS= read -r service; do
    [[ -n "$service" ]] || continue
    systemctl restart "$service" || return 1
  done <"$manifest"
}

cmd_self_update() {
  need_root
  need_cmd curl
  need_cmd sha256sum
  need_jq
  local tmp latest stamp backup_dir service manifest installed comparison
  local install_ok=0
  tmp="$(mktemp -d)"
  download_etxr_release_script "$tmp"
  latest="$(cat "$tmp/VERSION")"
  installed="$(etxr_installed_version)"
  comparison="$(etxr_version_compare "$VERSION" "$latest")"
  printf '当前运行版本：%s\n服务器安装版本：%s\n目标版本：%s\n' \
    "$VERSION" "$installed" "$latest"
  if [[ "$comparison" == 1 && "$FORCE" -ne 1 ]]; then
    rm -rf "$tmp"
    die "当前运行版本比 GitHub 最新正式版更新；如确需降级，请加 --force"
  fi
  if [[ "$installed" =~ ^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$ ]] &&
     [[ "$(etxr_version_compare "$installed" "$latest")" == 1 ]] &&
     [[ "$FORCE" -ne 1 ]]; then
    rm -rf "$tmp"
    die "服务器已安装版本比 GitHub 最新正式版更新；如确需降级，请加 --force"
  fi
  if [[ "$VERSION" == "$latest" && "$installed" == "$latest" && "$FORCE" -ne 1 ]]; then
    rm -rf "$tmp"
    log "ETXR is already up to date"
    return
  fi
  confirm "确认更新 ETXR 脚本、Go 数据面和控制组件" || {
    rm -rf "$tmp"
    return
  }

  if [[ -f "$STATE_FILE" ]]; then
    ETXR_SELF_BIN="$SELF_BIN" "$tmp/etxr.sh" --state "$STATE_FILE" validate
  fi

  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_dir="$BACKUP_DIR/self-update/${installed}-to-${latest}-${stamp}"
  mkdir -p "$backup_dir"
  [[ ! -e "$SELF_BIN" ]] || cp -a "$SELF_BIN" "$backup_dir/etxr"
  [[ ! -e "$DATAPLANE_BIN" ]] || cp -a "$DATAPLANE_BIN" "$backup_dir/etxr-dataplane"
  [[ ! -e "$CONTROL_HELPER" ]] || cp -a "$CONTROL_HELPER" "$backup_dir/control.py"
  manifest="$backup_dir/active-services"
  : >"$manifest"
  if command -v systemctl >/dev/null 2>&1; then
    for service in etxr-control.service etxr-agent.service \
      etxr-limiter.service etxr-meter.service etxr-domain-audit.service; do
      systemctl is-active --quiet "$service" 2>/dev/null && printf '%s\n' "$service" >>"$manifest"
    done
  fi

  ensure_parent "$SELF_BIN"
  install -m 755 "$tmp/etxr.sh" "${SELF_BIN}.new"
  mv -f "${SELF_BIN}.new" "$SELF_BIN"
  if ETXR_SELF_BIN="$SELF_BIN" ETXR_DATAPLANE_BIN="$DATAPLANE_BIN" \
      ETXR_CONTROL_HELPER="$CONTROL_HELPER" ETXR_RUNTIME="$RUNTIME_DIR" \
      ETXR_BACKUPS="$BACKUP_DIR" "$SELF_BIN" install --components dataplane &&
     [[ "$($SELF_BIN version 2>/dev/null || true)" == "$latest" ]] &&
     [[ "$($DATAPLANE_BIN version 2>/dev/null || true)" == "$latest" ]] &&
     restart_previously_active_etxr_services "$manifest"; then
    install_ok=1
  fi

  if (( ! install_ok )); then
    warn "ETXR 更新检查或服务重启失败，正在恢复旧版本"
    self_update_restore_file "$backup_dir/etxr" "$SELF_BIN"
    self_update_restore_file "$backup_dir/etxr-dataplane" "$DATAPLANE_BIN"
    self_update_restore_file "$backup_dir/control.py" "$CONTROL_HELPER"
    restart_previously_active_etxr_services "$manifest" || true
    rm -rf "$tmp"
    die "ETXR 更新失败，已恢复更新前版本"
  fi
  rm -rf "$tmp"
  log "ETXR updated: $installed -> $latest"
  printf '%s更新完成。重新进入菜单后会显示 v%s。%s\n' \
    "$C_GREEN" "$latest" "$C_RESET"
}

cmd_self() {
  local action="${1:-status}"
  case "$action" in
    status) cmd_self_status ;;
    check-update) cmd_self_check_update ;;
    update) cmd_self_update ;;
    *) die "Usage: etxr self status|check-update|update" ;;
  esac
}

xray_current_version() {
  if [[ -x "$XRAY_BIN" ]]; then
    "$XRAY_BIN" version 2>/dev/null | awk 'NR == 1 {print $2}'
  else
    printf '未安装'
  fi
}

xray_latest_version() {
  need_cmd curl
  need_jq
  curl --proto '=https' --tlsv1.2 -fsSL \
    https://api.github.com/repos/XTLS/Xray-core/releases/latest |
    jq -r '.tag_name | ltrimstr("v")'
}

cmd_xray_status() {
  printf '%sXray 版本：%s%s\n' "$C_CYAN" "$(xray_current_version)" "$C_RESET"
  if command -v systemctl >/dev/null 2>&1; then
    local active enabled pid
    active="$(systemctl is-active etxr-xray.service 2>/dev/null || true)"
    enabled="$(systemctl is-enabled etxr-xray.service 2>/dev/null || true)"
    pid="$(systemctl show etxr-xray.service -p MainPID --value 2>/dev/null || printf '0')"
    printf '服务状态：%s\n开机启动：%s\n主进程 PID：%s\n' \
      "${active:-unknown}" "${enabled:-unknown}" "${pid:-0}"
    if [[ "${pid:-0}" =~ ^[1-9][0-9]*$ ]]; then
      ps -p "$pid" -o pid,ppid,user,%cpu,%mem,rss,etime,args --no-headers 2>/dev/null || true
    fi
  fi
  if command -v ss >/dev/null 2>&1; then
    printf '\n%sXray 监听端口：%s\n' "$C_CYAN" "$C_RESET"
    ss -lntup 2>/dev/null | grep -E 'xray|etxr' || printf '未发现 Xray 监听端口\n'
  fi
}

cmd_xray_service_action() {
  local action="$1"
  need_root
  need_cmd systemctl
  case "$action" in
    start)
      systemctl enable --now etxr-xray.service
      ;;
    stop)
      systemctl stop etxr-xray.service
      ;;
    restart)
      if [[ -f "$STATE_FILE" ]]; then
        require_state
        local config
        config="$(jq -r '.xray.config_path' "$STATE_FILE")"
        [[ ! -f "$config" ]] || "$XRAY_BIN" run -test -config "$config"
      fi
      systemctl restart etxr-xray.service
      ;;
    *) die "Unknown Xray service action: $action" ;;
  esac
  cmd_xray_status
}

cmd_xray_logs() {
  local lines="${1:-80}"
  need_cmd journalctl
  journalctl -u etxr-xray.service -n "$lines" --no-pager
}

cmd_xray_follow() {
  need_cmd journalctl
  printf '%s按 Ctrl+C 退出实时日志%s\n' "$C_YELLOW" "$C_RESET"
  journalctl -u etxr-xray.service -f
}

xray_monitor_snapshot() {
  local active pid established=0
  active="$(systemctl is-active etxr-xray.service 2>/dev/null || true)"
  pid="$(systemctl show etxr-xray.service -p MainPID --value 2>/dev/null || printf '0')"
  printf '%s%sXray 实时监控%s  %s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$(date '+%F %T')"
  printf '服务：%-10s 版本：%s  PID：%s\n' "${active:-unknown}" "$(xray_current_version)" "${pid:-0}"
  if [[ "${pid:-0}" =~ ^[1-9][0-9]*$ ]]; then
    ps -p "$pid" -o 'pid=,user=,%cpu=,%mem=,rss=,etime=,cmd=' 2>/dev/null || true
    if command -v ss >/dev/null 2>&1; then
      established="$(ss -ntpH state established 2>/dev/null |
        awk -v p="pid=${pid}," 'index($0,p) {n++} END {print n+0}')"
      printf '活动 TCP 连接：%s\n' "$established"
      printf '\n监听端口：\n'
      ss -lntup 2>/dev/null | grep -E 'xray|etxr' || true
    fi
  fi
  printf '\n最近日志：\n'
  journalctl -u etxr-xray.service -n 12 --no-pager 2>/dev/null || true
}

cmd_xray_monitor() {
  need_cmd systemctl
  if [[ ! -t 0 || ! -t 1 ]]; then
    xray_monitor_snapshot
    return
  fi
  local key=""
  while true; do
    clear_screen
    xray_monitor_snapshot
    printf '\n%s每 2 秒刷新，按 q 返回%s\n' "$C_YELLOW" "$C_RESET"
    if read -r -s -n 1 -t 2 key; then
      [[ "$key" != "q" && "$key" != "Q" ]] || break
    fi
  done
}

cmd_xray_check_update() {
  local current latest
  current="$(xray_current_version)"
  latest="$(xray_latest_version)"
  printf '当前版本：%s\n最新版本：%s\n' "$current" "$latest"
  if [[ "$current" == "$latest" ]]; then
    printf '%s已经是最新版本。%s\n' "$C_GREEN" "$C_RESET"
  else
    printf '%s发现可更新版本。%s\n' "$C_YELLOW" "$C_RESET"
  fi
}

cmd_xray_update() {
  need_root
  need_cmd curl
  need_cmd unzip
  need_cmd sha256sum
  need_jq
  local current tmp latest candidate config="" stamp backup="" was_active=0
  current="$(xray_current_version)"
  tmp="$(mktemp -d)"
  download_xray_release "$tmp"
  latest="$(sed 's/^v//' "$tmp/VERSION")"
  candidate="$tmp/unpacked/xray"
  "$candidate" version >/dev/null

  printf '当前版本：%s\n目标版本：%s\n' "$current" "$latest"
  if [[ "$current" == "$latest" && "$FORCE" -ne 1 ]]; then
    rm -rf "$tmp"
    log "Xray is already up to date"
    return
  fi
  confirm "确认更新 Xray" || {
    rm -rf "$tmp"
    return
  }

  if [[ -f "$STATE_FILE" ]]; then
    require_state
    config="$(jq -r '.xray.config_path' "$STATE_FILE")"
    if [[ -f "$config" ]]; then
      "$candidate" run -test -config "$config"
    elif [[ -f "$GENERATED_DIR/xray.json" ]]; then
      "$candidate" run -test -config "$GENERATED_DIR/xray.json"
    fi
  fi

  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$BACKUP_DIR/xray-binary"
  if [[ -x "$XRAY_BIN" ]]; then
    backup="$BACKUP_DIR/xray-binary/xray-${current}-${stamp}"
    install -m 755 "$XRAY_BIN" "$backup"
  fi
  if systemctl is-active --quiet etxr-xray.service 2>/dev/null; then
    was_active=1
  fi

  ensure_parent "$XRAY_BIN"
  install -m 755 "$candidate" "${XRAY_BIN}.new"
  mv -f "${XRAY_BIN}.new" "$XRAY_BIN"
  mkdir -p /usr/local/share/xray
  [[ ! -f "$tmp/unpacked/geoip.dat" ]] ||
    install -m 644 "$tmp/unpacked/geoip.dat" /usr/local/share/xray/
  [[ ! -f "$tmp/unpacked/geosite.dat" ]] ||
    install -m 644 "$tmp/unpacked/geosite.dat" /usr/local/share/xray/

  if (( was_active )); then
    if ! systemctl restart etxr-xray.service; then
      warn "Xray restart failed; rolling back binary"
      [[ -n "$backup" ]] || die "Xray update failed and no previous binary exists"
      install -m 755 "$backup" "$XRAY_BIN"
      systemctl restart etxr-xray.service || true
      rm -rf "$tmp"
      die "Xray update rolled back"
    fi
  fi
  rm -rf "$tmp"
  log "Xray updated: $current -> $latest"
  cmd_xray_status
}

cmd_xray() {
  local action="${1:-status}"; shift || true
  case "$action" in
    status) cmd_xray_status ;;
    start|stop|restart) cmd_xray_service_action "$action" ;;
    logs) cmd_xray_logs "${1:-80}" ;;
    follow) cmd_xray_follow ;;
    monitor) cmd_xray_monitor ;;
    check-update) cmd_xray_check_update ;;
    update) cmd_xray_update ;;
    version) xray_current_version; printf '\n' ;;
    *) die "Usage: etxr xray status|start|stop|restart|logs|follow|monitor|check-update|update|version" ;;
  esac
}

base64url_encode() {
  base64 -w 0 | tr '+/' '-_' | tr -d '='
}

base64url_decode() {
  local input="$1" padding
  padding=$(( (4 - ${#input} % 4) % 4 ))
  {
    printf '%s' "$input"
    printf '%*s' "$padding" '' | tr ' ' '='
  } | tr '_-' '/+'
}

ensure_pair_signing_key() {
  need_cmd openssl
  mkdir -p "$PAIR_KEY_DIR"
  chmod 700 "$PAIR_KEY_DIR"
  if [[ ! -s "$PAIR_PRIVATE_KEY" || ! -s "$PAIR_PUBLIC_KEY" ]]; then
    local tmp_dir
    tmp_dir="$(mktemp -d "$PAIR_KEY_DIR/.pair-key.XXXXXX")"
    openssl genpkey -algorithm ED25519 -out "$tmp_dir/private" >/dev/null 2>&1 ||
      die "生成 Pair 签名私钥失败"
    openssl pkey -in "$tmp_dir/private" -pubout -out "$tmp_dir/public" >/dev/null 2>&1 ||
      die "生成 Pair 签名公钥失败"
    chmod 600 "$tmp_dir/private"
    chmod 644 "$tmp_dir/public"
    mv -f "$tmp_dir/private" "$PAIR_PRIVATE_KEY"
    mv -f "$tmp_dir/public" "$PAIR_PUBLIC_KEY"
    rmdir "$tmp_dir" 2>/dev/null || true
  fi
  chmod 600 "$PAIR_PRIVATE_KEY"
  chmod 644 "$PAIR_PUBLIC_KEY"
}

pair_public_fingerprint() {
  ensure_pair_signing_key
  openssl pkey -pubin -in "$PAIR_PUBLIC_KEY" -outform DER 2>/dev/null |
    sha256sum | awk '{print toupper(substr($1,1,32))}'
}

pair_encode() {
  local json="$1" payload public signature checksum tmp_dir
  ensure_pair_signing_key
  tmp_dir="$(mktemp -d)"
  printf '%s' "$json" | gzip -9 -c | base64url_encode >"$tmp_dir/payload"
  payload="$(cat "$tmp_dir/payload")"
  printf '%s' "$payload" >"$tmp_dir/payload.raw"
  openssl pkeyutl -sign -rawin -inkey "$PAIR_PRIVATE_KEY" \
    -in "$tmp_dir/payload.raw" -out "$tmp_dir/signature" >/dev/null 2>&1 ||
    die "生成 Pair 签名失败"
  public="$(base64url_encode <"$PAIR_PUBLIC_KEY")"
  signature="$(base64url_encode <"$tmp_dir/signature")"
  checksum="$(printf '%s.%s.%s' "$payload" "$public" "$signature" |
    sha256sum | awk '{print substr($1,1,24)}')"
  rm -rf "$tmp_dir"
  printf 'ER2.%s.%s.%s.%s\n' "$payload" "$public" "$signature" "$checksum"
}

pair_decode() {
  local pairing_id="$1" trusted_fingerprint="${2:-}"
  local prefix payload public signature checksum actual fingerprint tmp_dir
  local gzip_status bundle_size
  (( ${#pairing_id} <= PAIR_ID_MAX_BYTES )) ||
    die "Pair ID 超过大小限制"
  IFS='.' read -r prefix payload public signature checksum <<<"$pairing_id"
  [[ "$prefix" == "ER2" && -n "$payload" && -n "$public" &&
     -n "$signature" && -n "$checksum" ]] ||
    die "无效的配对 ID 格式；请使用新的 ER2 配对 ID"
  [[ "$payload" =~ ^[A-Za-z0-9_-]+$ && "$public" =~ ^[A-Za-z0-9_-]+$ &&
     "$signature" =~ ^[A-Za-z0-9_-]+$ && "$checksum" =~ ^[0-9a-fA-F]{24}$ ]] ||
    die "配对 ID 含有无效字符"
  (( ${#public} <= 4096 && ${#signature} <= 4096 )) ||
    die "Pair ID 公钥或签名超过大小限制"
  actual="$(printf '%s.%s.%s' "$payload" "$public" "$signature" |
    sha256sum | awk '{print substr($1,1,24)}')"
  [[ "${actual,,}" == "${checksum,,}" ]] ||
    die "配对 ID 校验失败，可能复制不完整"
  tmp_dir="$(mktemp -d)"
  if ! base64url_decode "$payload" | base64 -d >"$tmp_dir/bundle.gz" ||
     ! base64url_decode "$public" | base64 -d >"$tmp_dir/public" ||
     ! base64url_decode "$signature" | base64 -d >"$tmp_dir/signature"; then
    rm -rf "$tmp_dir"
    die "配对 ID 解码失败"
  fi
  printf '%s' "$payload" >"$tmp_dir/payload"
  if ! openssl pkeyutl -verify -rawin -pubin -inkey "$tmp_dir/public" \
      -in "$tmp_dir/payload" -sigfile "$tmp_dir/signature" >/dev/null 2>&1; then
    rm -rf "$tmp_dir"
    die "Pair ID 签名验证失败"
  fi
  fingerprint="$(openssl pkey -pubin -in "$tmp_dir/public" -outform DER 2>/dev/null |
    sha256sum | awk '{print toupper(substr($1,1,32))}')"
  [[ -n "$fingerprint" ]] || {
    rm -rf "$tmp_dir"
    die "无法读取 Pair 签名指纹"
  }
  if [[ -n "$trusted_fingerprint" &&
        "${trusted_fingerprint^^}" != "$fingerprint" ]]; then
    rm -rf "$tmp_dir"
    die "Pair 签名指纹不匹配；请核对主服务器显示的指纹"
  fi
  # Do not parse attacker-controlled compressed content before authentication.
  set +o pipefail
  gzip -dc "$tmp_dir/bundle.gz" 2>/dev/null |
    head -c "$((PAIR_BUNDLE_MAX_BYTES + 1))" >"$tmp_dir/bundle"
  gzip_status="${PIPESTATUS[0]}"
  set -o pipefail
  bundle_size="$(wc -c <"$tmp_dir/bundle")"
  if (( gzip_status != 0 && gzip_status != 141 )); then
    rm -rf "$tmp_dir"
    die "Pair ID 压缩数据无效"
  fi
  if (( bundle_size > PAIR_BUNDLE_MAX_BYTES )); then
    rm -rf "$tmp_dir"
    die "Pair ID 解压后的配置超过大小限制"
  fi
  cat "$tmp_dir/bundle"
  rm -rf "$tmp_dir"
}

validate_pair_bundle() {
  jq -e '
    def valid_overlay_ipv4:
      type == "string" and
      (split(".") | length == 4 and
        all(.[]; test("^[0-9]{1,3}$") and
          ((tonumber) >= 0 and (tonumber) <= 255))) and
      ((split(".")[-1] | tonumber) >= 1 and
       (split(".")[-1] | tonumber) <= 254);
    def subnet24:
      split(".")[0:3] | join(".");
    (.version == 2) and
    (.expires_at | type == "number") and
    (.worker.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) and
    (.worker.easytier_ip | valid_overlay_ipv4) and
    (.master.easytier_ip | valid_overlay_ipv4) and
    ((.worker.easytier_ip | subnet24) == (.master.easytier_ip | subnet24)) and
    (.worker.easytier_ip != .master.easytier_ip) and
    (.worker.public_host | type == "string" and length <= 253 and
      (length == 0 or test("^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$"))) and
    (.master.address | type == "string" and test("^[A-Za-z0-9.-]+$")) and
    (.master.tcp_port | type == "number" and floor == . and . >= 1 and . <= 65535) and
    (.master.source_cidr | type == "string" and test("^(|[0-9]{1,3}(\\.[0-9]{1,3}){3}/32)$")) and
    (.easytier.network_name | type == "string" and test("^[A-Za-z0-9._:-]{1,64}$")) and
    (.easytier.network_secret | type == "string" and test("^[A-Za-z0-9._:@+-]{1,256}$")) and
    (.control.base_url | type == "string" and test("^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~/-]*)?$")) and
    (.control.node_id == .worker.name) and
    (.control.token | type == "string" and test("^[0-9a-fA-F]{64}$")) and
    (.users | type == "array") and
    (([.users[].name] | length) == ([.users[].name] | unique | length)) and
    (([.users[].uuid] | length) == ([.users[].uuid] | unique | length)) and
    (([.users[].subscription_token] | length) ==
      ([.users[].subscription_token] | unique | length)) and
    all(.users[];
      (.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) and
      (.uuid | type == "string" and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$")) and
      (.hy2_password | type == "string" and length <= 512) and
      (.enabled | type == "boolean") and
      (.expires_at == null or (.expires_at | type == "string")) and
      (.routes | type == "array" and all(.[]; type == "string" and test("^\\*?$|^[A-Za-z0-9._-]{1,64}$"))) and
      ((.enabled_nodes // ["*"]) | type == "array" and
        length == (unique | length) and
        all(.[]; type == "string" and
          test("^\\*$|^[A-Za-z0-9][A-Za-z0-9._-]{0,63}/((xhttp|reality)/[A-Za-z0-9][A-Za-z0-9._-]{0,63}|hy2)$"))) and
      (.subscription_prefix | type == "string" and test("^[0-9a-fA-F]{8}$")) and
      (.subscription_token | type == "string" and test("^[0-9a-fA-F]{40}$")) and
      ((.speed_limit // {up_mbps: 0, down_mbps: 0}) |
        type == "object" and
        (.up_mbps | type == "number" and floor == . and . >= 0 and . <= 100000) and
        (.down_mbps | type == "number" and floor == . and . >= 0 and . <= 100000)) and
      ((.usage_epoch // "") | type == "string" and length <= 128)
    ) and
    (.relay.uuid | type == "string" and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$")) and
    (.relay.private_port | type == "number" and floor == . and . >= 1 and . <= 65535) and
    (.relay.public_port | type == "number" and floor == . and . >= 1 and . <= 65535) and
    (.relay.listen_port | type == "number" and floor == . and . >= 1 and . <= 65535) and
    (.direct.user_uuid | type == "string" and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$")) and
    (.direct.xhttp.enabled | type == "boolean") and
    (.direct.xhttp.public_port | type == "number" and floor == . and . >= 1 and . <= 65535) and
    (.direct.xhttp.listen_port | type == "number" and floor == . and . >= 1 and . <= 65535) and
    (.direct.xhttp.path | type == "string" and test("^/[A-Za-z0-9._~/-]+$") and (contains("//") | not) and (contains("..") | not)) and
    (.direct.reality.enabled | type == "boolean") and
    (.direct.reality.port | type == "number" and floor == . and . >= 1 and . <= 65535) and
    (.direct.reality.path | type == "string" and test("^/[A-Za-z0-9._~/-]+$") and (contains("//") | not) and (contains("..") | not)) and
    (.direct.reality.target | type == "string" and test("^[A-Za-z0-9.-]+:[0-9]{1,5}$")) and
    (.direct.reality.server_name | type == "string" and test("^[A-Za-z0-9.-]+$")) and
    (.direct.reality.short_id | type == "string" and test("^[0-9a-fA-F]{2,32}$")) and
    (.direct.hysteria2.enabled | type == "boolean") and
    (.direct.hysteria2.port | type == "number" and floor == . and . >= 1 and . <= 65535) and
    ((.direct.hysteria2.shared_udp443 // false) | type == "boolean") and
    ((.direct.hysteria2.shared_udp443 // false) == false or
      (.direct.hysteria2.enabled == true and .direct.hysteria2.port == 443)) and
    (.direct.hysteria2.password | type == "string" and length <= 512) and
    (.direct.hysteria2.obfs_password | type == "string" and length <= 512) and
    (.direct.hysteria2.masquerade | type == "string" and test("^https?://[^[:space:]]+$")) and
    ([
      .relay.private_port,
      (if .relay.public_enabled then .relay.listen_port else empty end),
      (if .direct.xhttp.enabled then .direct.xhttp.listen_port else empty end),
      (if .direct.reality.enabled then .direct.reality.port else empty end)
    ] | length == (unique | length))
  ' <<<"$1" >/dev/null
}

resolve_ipv4_cidr() {
  local host="$1" ip=""
  if valid_ipv4 "$host"; then
    ip="$host"
  elif command -v getent >/dev/null 2>&1; then
    ip="$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1 {print $1}')"
  fi
  [[ -z "$ip" ]] || valid_ipv4 "$ip" || return 0
  [[ -z "$ip" ]] || printf '%s/32' "$ip"
}

generate_vlessenc_x25519_pair() {
  [[ -x "$XRAY_BIN" ]] || die "请先安装 Xray"
  local output
  output="$("$XRAY_BIN" vlessenc)"
  # Xray may print multiple suites; use the final recommended pair
  # (currently the ML-KEM authenticated profile).
  PAIR_DECRYPTION="$(awk -F'"' '/"decryption"/ {v=$4} END {print v}' <<<"$output")"
  PAIR_ENCRYPTION="$(awk -F'"' '/"encryption"/ {v=$4} END {print v}' <<<"$output")"
  [[ -n "$PAIR_DECRYPTION" && -n "$PAIR_ENCRYPTION" ]] ||
    die "无法解析 xray vlessenc 输出"
}

cmd_cluster_master_init() {
  require_state
  [[ "$(jq -r '.node.role' "$STATE_FILE")" == "gateway" ||
     "$(jq -r '.node.role' "$STATE_FILE")" == "hybrid" ]] ||
    die "Only a gateway/hybrid node can initialize the EasyTier master"
  local ip="10.100.0.1" port=11010 endpoint="" network_name="" network_secret=""
  while (($#)); do
    case "$1" in
      --ip) ip="$2"; shift 2 ;;
      --port) port="$2"; shift 2 ;;
      --endpoint) endpoint="$2"; shift 2 ;;
      --network-name) network_name="$2"; shift 2 ;;
      --network-secret) network_secret="$2"; shift 2 ;;
      --help)
        echo "Usage: etxr cluster master-init [--ip 10.100.0.1] [--port 11010] [--endpoint A_IP_OR_DOMAIN]"
        return ;;
      *) die "Unknown master-init option: $1" ;;
    esac
  done
  endpoint="${endpoint:-$(jq -r '.node.address' "$STATE_FILE")}"
  network_name="${network_name:-er-$(random_hex 8)}"
  network_secret="${network_secret:-$(random_hex 24)}"
  valid_ipv4 "$ip" || die "Invalid EasyTier overlay IPv4 address"
  valid_hostname "$endpoint" || die "Invalid EasyTier public endpoint"
  valid_port "$port" || die "Invalid EasyTier TCP port"
  valid_secret_value "$network_name" || die "Invalid EasyTier network name"
  valid_secret_value "$network_secret" || die "Invalid EasyTier network secret"
  state_update '
    .easytier = {
      enabled: true,
      ipv4: $ip,
      public_endpoint: $endpoint,
      network_name: $name,
      network_secret: $secret,
      peer: "",
      tcp_port: $port
    } |
    .paired_nodes = (.paired_nodes // []) |
    .xray.relay_inbounds = (.xray.relay_inbounds // [])
  ' --arg ip "$ip" --arg endpoint "$endpoint" \
    --arg name "$network_name" --arg secret "$network_secret" \
    --argjson port "$port"
  log "EasyTier master initialized at $ip, public TCP ${endpoint}:$port"
}

next_easytier_worker_ip() {
  require_state
  local master_ip prefix candidate octet
  master_ip="$(jq -r '.easytier.ipv4 // ""' "$STATE_FILE")"
  valid_ipv4 "$master_ip" || die "主服务器 EasyTier 私网 IP 无效：${master_ip:-未设置}"
  prefix="${master_ip%.*}"
  for ((octet=11; octet<=250; octet++)); do
    candidate="${prefix}.${octet}"
    [[ "$candidate" != "$master_ip" ]] || continue
    if ! jq -e --arg ip "$candidate" \
      '.paired_nodes[]? | select(.easytier_ip == $ip)' "$STATE_FILE" >/dev/null; then
      printf '%s' "$candidate"
      return
    fi
  done
  die "主服务器 EasyTier 网段 ${prefix}.0/24 的从服务器地址池已用完"
}

cmd_pair_create() {
  require_state
  ensure_control_state
  [[ "$(jq -r '.easytier.enabled // false' "$STATE_FILE")" == "true" ]] ||
    die "请先运行 cluster master-init"
  [[ -z "$(jq -r '.easytier.peer // ""' "$STATE_FILE")" ]] ||
    die "只能在主服务器创建从服务器配对 ID"
  local name="" public_host="" backup_port=29000 backup_listen_port=29000
  local reality_port=18443 hy2_port=28443
  local reality_sni="aod.itunes.apple.com" reality_target="aod.itunes.apple.com:443"
  local xhttp_enabled=false reality_enabled=true hy2_enabled=true
  local hy2_shared_udp443=false
  local xhttp_port=18000 xhttp_listen_port=18000 xhttp_path=""
  local reality_path="" hy2_masquerade="https://www.cloudflare.com"
  local relay_uuid="" user_uuid="" hy2_password="" hy2_obfs="" reality_short=""
  local relay_private_port=19000
  local hy2_up=0 hy2_down=0
  local expires_minutes=30 expires_at
  while (($#)); do
    case "$1" in
      --name) name="$2"; shift 2 ;;
      --public-host) public_host="$2"; shift 2 ;;
      --public-relay-port) backup_port="$2"; shift 2 ;;
      --public-listen-port) backup_listen_port="$2"; shift 2 ;;
      --private-relay-port) relay_private_port="$2"; shift 2 ;;
      --xhttp-enabled) xhttp_enabled=true; shift ;;
      --no-xhttp) xhttp_enabled=false; shift ;;
      --xhttp-port) xhttp_port="$2"; shift 2 ;;
      --xhttp-listen-port) xhttp_listen_port="$2"; shift 2 ;;
      --xhttp-path) xhttp_path="$2"; shift 2 ;;
      --reality-enabled) reality_enabled=true; shift ;;
      --no-reality) reality_enabled=false; shift ;;
      --reality-port) reality_port="$2"; shift 2 ;;
      --reality-path) reality_path="$2"; shift 2 ;;
      --hy2-enabled) hy2_enabled=true; shift ;;
      --no-hy2) hy2_enabled=false; shift ;;
      --hy2-port) hy2_port="$2"; shift 2 ;;
      --hy2-share-udp443) hy2_shared_udp443=true; shift ;;
      --hy2-no-share-udp443) hy2_shared_udp443=false; shift ;;
      --hy2-masquerade) hy2_masquerade="$2"; shift 2 ;;
      --hy2-up-mbps) hy2_up="$2"; shift 2 ;;
      --hy2-down-mbps) hy2_down="$2"; shift 2 ;;
      --relay-uuid) relay_uuid="$2"; shift 2 ;;
      --user-uuid) user_uuid="$2"; shift 2 ;;
      --hy2-password) hy2_password="$2"; shift 2 ;;
      --hy2-obfs-password) hy2_obfs="$2"; shift 2 ;;
      --reality-short-id) reality_short="$2"; shift 2 ;;
      --reality-sni) reality_sni="$2"; shift 2 ;;
      --reality-target) reality_target="$2"; shift 2 ;;
      --expires-minutes) expires_minutes="$2"; shift 2 ;;
      --expires-hours)
        [[ "${2:-}" =~ ^[0-9]+$ ]] || die "Invalid expiry hours"
        expires_minutes="$((10#$2 * 60))"
        shift 2
        ;;
      --help)
        cat <<'EOF'
Usage:
  etxr pair create --name worker1 [--public-host PUBLIC_HOST]
    [--public-relay-port EXTERNAL_PORT] [--public-listen-port INTERNAL_PORT]
    [--reality-port 18443] [--hy2-port 443 --hy2-share-udp443]
    [--expires-minutes 30]

When --public-host is set, the public relay is primary and EasyTier is the
automatic fallback. Without --public-host, traffic uses EasyTier only. For a
NAT mapping, EXTERNAL_PORT maps to the worker's INTERNAL_PORT over TCP.
EOF
        return ;;
      *) die "Unknown pair create option: $1" ;;
    esac
  done
  [[ -n "$name" ]] || die "--name is required"
  valid_name "$name" || die "Invalid worker name"
  [[ -z "$public_host" ]] || valid_hostname "$public_host" || die "Invalid public host"
  [[ "$expires_minutes" =~ ^[0-9]+$ ]] ||
    die "Invalid expiry minutes"
  (( 10#$expires_minutes >= 1 && 10#$expires_minutes <= 525600 )) ||
    die "Expiry must be between 1 minute and 525600 minutes"
  expires_minutes="$((10#$expires_minutes))"
  expires_at="$(( $(date +%s) + expires_minutes * 60 ))"
  valid_port "$backup_port" || die "Invalid backup port"
  valid_port "$backup_listen_port" || die "Invalid backup listen port"
  valid_port "$relay_private_port" || die "Invalid private relay port"
  valid_port "$xhttp_port" || die "Invalid XHTTP public port"
  valid_port "$xhttp_listen_port" || die "Invalid XHTTP listen port"
  valid_port "$reality_port" || die "Invalid Reality port"
  valid_port "$hy2_port" || die "Invalid Hysteria2 port"
  valid_mbps "$hy2_up" || die "Invalid Hysteria2 upload Mbps"
  valid_mbps "$hy2_down" || die "Invalid Hysteria2 download Mbps"
  [[ "$xhttp_enabled" == "true" || "$xhttp_enabled" == "false" ]] ||
    die "Invalid XHTTP enabled flag"
  [[ "$reality_enabled" == "true" || "$reality_enabled" == "false" ]] ||
    die "Invalid Reality enabled flag"
  [[ "$hy2_enabled" == "true" || "$hy2_enabled" == "false" ]] ||
    die "Invalid Hysteria2 enabled flag"
  [[ "$hy2_shared_udp443" == "true" || "$hy2_shared_udp443" == "false" ]] ||
    die "Invalid Hysteria2 UDP 443 sharing flag"
  if [[ "$hy2_shared_udp443" == "true" &&
        ( "$hy2_enabled" != "true" || "$hy2_port" != "443" ) ]]; then
    die "Worker Hysteria2 UDP 443 sharing requires enabled HY2 on port 443"
  fi
  xhttp_path="${xhttp_path:-$(random_path)}"
  reality_path="${reality_path:-$(random_path)}"
  xhttp_path="$(normalize_path "$xhttp_path")"
  reality_path="$(normalize_path "$reality_path")"
  valid_http_path "$xhttp_path" || die "Invalid XHTTP Path"
  valid_http_path "$reality_path" || die "Invalid Reality Path"
  valid_url "$hy2_masquerade" || die "Invalid Hysteria2 masquerade URL"
  jq -e --arg n "$name" '
    (.paired_nodes[]? | select(.name == $n)),
    (.xray.routes[]? | select(.name == $n)),
    (.xray.exits[]? | select(.name == $n))
  ' "$STATE_FILE" >/dev/null && die "Worker, route, or exit already exists: $name"

  local worker_ip master_ip master_address master_port master_source
  local reality_keys reality_private reality_public
  local bundle pairing_id route_port route_path control_token control_url
  worker_ip="$(next_easytier_worker_ip)"
  master_ip="$(jq -r '.easytier.ipv4' "$STATE_FILE")"
  master_address="$(jq -r '.easytier.public_endpoint // .node.address' "$STATE_FILE")"
  master_port="$(jq -r '.easytier.tcp_port' "$STATE_FILE")"
  master_source="$(resolve_ipv4_cidr "$master_address" || true)"
  if [[ -n "$public_host" && -z "$master_source" ]]; then
    die "启用公网直连时必须能把主服务器的 EasyTier 公网地址解析为 IPv4；请用主服务器公网 IP 重新初始化 cluster"
  fi
  relay_uuid="${relay_uuid:-$(random_uuid)}"
  user_uuid="${user_uuid:-$(random_uuid)}"
  hy2_password="${hy2_password:-$(random_password)}"
  hy2_obfs="${hy2_obfs:-$(random_password)}"
  reality_short="${reality_short:-$(random_hex 8)}"
  if [[ "$hy2_enabled" == "true" ]]; then
    ensure_hy2_passwords_for_node "$name"
  fi
  valid_uuid "$relay_uuid" || die "Invalid relay UUID"
  valid_uuid "$user_uuid" || die "Invalid direct user UUID"
  generate_vlessenc_x25519_pair
  reality_private=""
  reality_public=""
  if [[ "$reality_enabled" == "true" ]]; then
    reality_keys="$("$XRAY_BIN" x25519)"
    reality_private="$(awk -F': ' '/^PrivateKey:/ {print $2}' <<<"$reality_keys")"
    reality_public="$(awk -F': ' '/^Password/ {print $2; exit}' <<<"$reality_keys")"
    if [[ -z "$reality_public" ]]; then
      reality_public="$(awk -F': ' '/^PublicKey:/ {print $2; exit}' <<<"$reality_keys")"
    fi
    [[ -n "$reality_private" && -n "$reality_public" ]] ||
      die "无法解析 xray x25519 输出"
  fi
  route_port="$(next_route_port)"
  route_path="$(random_path)"
  control_token="$(random_hex 32)"
  control_url="$(control_base_url)"

  bundle="$(jq -n \
    --argjson expires "$expires_at" \
    --arg name "$name" --arg worker_ip "$worker_ip" \
    --arg master_ip "$master_ip" --arg master_address "$master_address" \
    --arg network_name "$(jq -r '.easytier.network_name' "$STATE_FILE")" \
    --arg network_secret "$(jq -r '.easytier.network_secret' "$STATE_FILE")" \
    --argjson master_port "$master_port" \
    --arg master_source "$master_source" \
    --arg public_host "$public_host" \
    --arg relay_uuid "$relay_uuid" \
    --arg decryption "$PAIR_DECRYPTION" --arg encryption "$PAIR_ENCRYPTION" \
    --argjson relay_private_port "$relay_private_port" \
    --argjson backup_port "$backup_port" \
    --argjson backup_listen_port "$backup_listen_port" \
    --argjson xhttp_enabled "$xhttp_enabled" \
    --argjson xhttp_port "$xhttp_port" \
    --argjson xhttp_listen_port "$xhttp_listen_port" \
    --arg xhttp_path "$xhttp_path" \
    --argjson reality_enabled "$reality_enabled" \
    --arg reality_private "$reality_private" --arg reality_public "$reality_public" \
    --arg reality_short "$reality_short" --arg reality_sni "$reality_sni" \
    --arg reality_target "$reality_target" --arg reality_path "$reality_path" \
    --argjson reality_port "$reality_port" --argjson hy2_enabled "$hy2_enabled" \
    --arg user_uuid "$user_uuid" --arg hy2_password "$hy2_password" \
    --arg hy2_obfs "$hy2_obfs" --argjson hy2_port "$hy2_port" \
    --argjson hy2_shared_udp443 "$hy2_shared_udp443" \
    --arg hy2_masquerade "$hy2_masquerade" \
    --argjson hy2_up "$hy2_up" --argjson hy2_down "$hy2_down" \
    --arg control_url "$control_url" --arg control_token "$control_token" \
    --argjson users "$(jq '.users' "$STATE_FILE")" '
    {
      version: 2,
      expires_at: $expires,
      worker: {
        name: $name,
        easytier_ip: $worker_ip,
        public_host: $public_host
      },
      master: {
        easytier_ip: $master_ip,
        address: $master_address,
        tcp_port: $master_port,
        source_cidr: $master_source
      },
      easytier: {
        network_name: $network_name,
        network_secret: $network_secret
      },
      control: {
        base_url: $control_url,
        node_id: $name,
        token: $control_token
      },
      users: $users,
      relay: {
        uuid: $relay_uuid,
        private_port: $relay_private_port,
        public_enabled: ($public_host != ""),
        public_port: $backup_port,
        listen_port: $backup_listen_port,
        decryption: $decryption,
        encryption: $encryption,
        flow: "xtls-rprx-vision",
        network: "raw"
      },
      direct: {
        user_uuid: $user_uuid,
        xhttp: {
          enabled: $xhttp_enabled,
          public_port: $xhttp_port,
          listen_port: $xhttp_listen_port,
          path: $xhttp_path
        },
        reality: {
          enabled: $reality_enabled,
          port: $reality_port,
          target: $reality_target,
          server_name: $reality_sni,
          private_key: $reality_private,
          public_key: $reality_public,
          short_id: $reality_short,
          path: $reality_path
        },
        hysteria2: {
          enabled: $hy2_enabled,
          port: $hy2_port,
          shared_udp443: $hy2_shared_udp443,
          password: $hy2_password,
          obfs_password: $hy2_obfs,
          masquerade: $hy2_masquerade,
          up_mbps: $hy2_up,
          down_mbps: $hy2_down
        }
      }
    }')"
  pairing_id="$(pair_encode "$bundle")"
  local pair_fingerprint
  pair_fingerprint="$(pair_public_fingerprint)"

  state_update '
    .xray.exits += [{
      name: $name,
      address: (if $public_host != "" then $public_host else $worker_ip end),
      port: (if $public_host != "" then $public_port else $private_port end),
      backup_address: (if $public_host != "" then $worker_ip else "" end),
      backup_port: $private_port,
      connection_preference: (if $public_host != "" then "public-primary" else "easytier-only" end),
      network: "raw",
      transport: "none",
      path: "",
      host: "",
      server_name: "",
      uuid: $uuid,
      encryption: $encryption,
      flow: "xtls-rprx-vision",
      fingerprint: "chrome"
    }] |
    .xray.routes += [{
      name: $name,
      path: $route_path,
      listen: "127.0.0.1",
      port: $route_port,
      target: $name,
      profile: "plain",
      host: "",
      decryption: "none",
      client_encryption: "none",
      flow: ""
    }] |
    .paired_nodes += [{
      name: $name,
      easytier_ip: $worker_ip,
      public_host: $public_host,
      connection_preference: (if $public_host != "" then "public-primary" else "easytier-only" end),
      public_port: $public_port,
      public_listen_port: $public_listen_port,
      private_relay_port: $private_port,
      control_token: $control_token,
      route_path: $route_path,
      route_port: $route_port,
      created_at: $created,
      expires_at: $expires
    }]
  ' --arg name "$name" --arg worker_ip "$worker_ip" --arg public_host "$public_host" \
    --arg control_token "$control_token" \
    --arg uuid "$relay_uuid" --arg encryption "$PAIR_ENCRYPTION" \
    --arg route_path "$route_path" --arg created "$(date -u +%FT%TZ)" \
    --argjson private_port "$relay_private_port" \
    --argjson public_port "$backup_port" \
    --argjson public_listen_port "$backup_listen_port" \
    --argjson backup_port "$backup_port" \
    --argjson backup_listen_port "$backup_listen_port" \
    --argjson route_port "$route_port" \
    --argjson expires "$expires_at"

  mkdir -p "$RUNTIME_DIR/pairs"
  printf '%s\n' "$pairing_id" | atomic_write "$RUNTIME_DIR/pairs/${name}.id"
  printf '\n%s配对 ID（请完整复制到从服务器）：%s\n\n%s\n\n' \
    "$C_GREEN" "$C_RESET" "$pairing_id"
  printf 'Pair 签名指纹（从服务器加入时必须核对）： %s\n' "$pair_fingerprint"
  printf '客户端通过主服务器访问该从服务器时使用的 XHTTP Path：%s\n' "$route_path"
  printf '从服务器加入 EasyTier 后使用的私网 IP：%s\n' "$worker_ip"
  if [[ -n "$public_host" ]]; then
    if [[ "$backup_port" == "$backup_listen_port" ]]; then
      printf '优先线路（公网直连）：主服务器 -> %s:%s（从服务器监听 TCP %s）\n' \
        "$public_host" "$backup_port" "$backup_listen_port"
    else
      printf '优先线路（公网端口映射）：主服务器 -> %s:%s -> 从服务器 TCP %s\n' \
        "$public_host" "$backup_port" "$backup_listen_port"
    fi
    printf '备用线路（公网失败后使用）：主服务器 -> EasyTier %s:%s\n' \
      "$worker_ip" "$relay_private_port"
    printf '防火墙要求：从服务器 TCP %s 只允许主服务器公网 IP 访问。\n' \
      "$backup_listen_port"
  else
    printf '唯一线路：主服务器 -> EasyTier %s:%s（无需开放公网端口）\n' \
      "$worker_ip" "$relay_private_port"
  fi
  printf '%s该 ID 包含组网密钥，有效期 %s 分钟，请勿公开；指纹用于防止 Pair ID 被篡改。%s\n' \
    "$C_YELLOW" "$expires_minutes" "$C_RESET"
}

generate_self_signed_cert() {
  local name="$1" san="${2:-$1}" cert_dir san_arg
  cert_dir="$RUNTIME_DIR/certs/$name"
  if valid_ipv4 "$san"; then
    san_arg="IP:${san}"
  else
    san_arg="DNS:${san}"
  fi
  mkdir -p "$cert_dir"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/CN=$name" \
    -addext "subjectAltName=${san_arg}" \
    -keyout "$cert_dir/privkey.pem" \
    -out "$cert_dir/fullchain.pem" >/dev/null 2>&1
  chmod 600 "$cert_dir/privkey.pem"
  printf '%s\n%s\n' "$cert_dir/fullchain.pem" "$cert_dir/privkey.pem"
}

tls_certificate_is_usable() {
  local cert="$1" key="$2" cert_pub key_pub
  [[ -f "$cert" && -r "$cert" && -f "$key" && -r "$key" ]] || return 1
  openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || return 1
  openssl pkey -in "$key" -noout >/dev/null 2>&1 || return 1
  cert_pub="$(
    openssl x509 -in "$cert" -pubkey -noout 2>/dev/null |
      openssl pkey -pubin -outform DER 2>/dev/null |
      sha256sum | awk '{print $1}'
  )"
  key_pub="$(
    openssl pkey -in "$key" -pubout -outform DER 2>/dev/null |
      sha256sum | awk '{print $1}'
  )"
  [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]]
}

tls_certificate_matches_name() {
  local cert="$1" name="$2"
  if valid_ipv4 "$name"; then
    openssl x509 -in "$cert" -noout -checkip "$name" >/dev/null 2>&1
  else
    openssl x509 -in "$cert" -noout -checkhost "$name" >/dev/null 2>&1
  fi
}

detect_public_ipv4() {
  local ip=""
  ip="$(curl -4 --proto '=https' --tlsv1.2 -fsS --max-time 8 \
    https://api.ipify.org 2>/dev/null || true)"
  if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s' "$ip"
}

bundle_worker_direct_config() {
  local bundle="$1" name domain address
  name="$(jq -r '.worker.name' <<<"$bundle")"
  address="$(jq -r '.worker.public_host // ""' <<<"$bundle")"
  address="${address:-$(detect_public_ipv4)}"
  domain="${address:-${name}.local}"
  jq -n \
    --arg domain "$domain" --arg address "$address" \
    --argjson direct "$(jq '.direct' <<<"$bundle")" '
    {
      domain: $domain,
      address: $address,
      nginx: {
        mode: "disabled",
        tls_port: 443,
        https_listen_port: 8443,
        shared_tcp443: false,
        auto_rebind_https: false,
        certificate: "",
        certificate_key: "",
        snippet_path: ""
      },
      xhttp: ($direct.xhttp + {behind_nginx: false}),
      reality: ($direct.reality + {listen_port: $direct.reality.port}),
      hysteria2: $direct.hysteria2
    }
  '
}

validate_worker_direct_config() {
  jq -e '
    (.domain | type == "string" and
      test("^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$")) and
    (.address | type == "string" and test("^[A-Za-z0-9.-]+$")) and
    (.nginx.mode == "disabled" or .nginx.mode == "snippet" or
      .nginx.mode == "standalone") and
    (.nginx.tls_port | type == "number" and . >= 1 and . <= 65535) and
    (.nginx.https_listen_port | type == "number" and . >= 1 and . <= 65535) and
    (.nginx.shared_tcp443 | type == "boolean") and
    (.nginx.auto_rebind_https | type == "boolean") and
    (.nginx.shared_tcp443 == false or
      (.nginx.mode != "disabled" and .nginx.tls_port == 443 and
       .nginx.https_listen_port != 443)) and
    (.nginx.auto_rebind_https == false or
      (.nginx.mode == "snippet" and .nginx.shared_tcp443 == true)) and
    (.nginx.certificate | type == "string" and
      (length == 0 or test("^/[A-Za-z0-9._/-]+$"))) and
    (.nginx.certificate_key | type == "string" and
      (length == 0 or test("^/[A-Za-z0-9._/-]+$"))) and
    (.nginx.snippet_path | type == "string" and
      (length == 0 or test("^/[A-Za-z0-9._/-]+$"))) and
    (.xhttp.enabled | type == "boolean") and
    (.xhttp.public_port | type == "number" and . >= 1 and . <= 65535) and
    (.xhttp.listen_port | type == "number" and . >= 1 and . <= 65535) and
    (.xhttp.behind_nginx | type == "boolean") and
    (.xhttp.behind_nginx == false or .nginx.mode != "disabled") and
    (.xhttp.behind_nginx == false or .xhttp.public_port == .nginx.tls_port) and
    (.xhttp.path | type == "string" and test("^/[A-Za-z0-9._~/-]+$") and
      (contains("//") | not) and (contains("..") | not)) and
    (.reality.enabled | type == "boolean") and
    (.reality.port | type == "number" and . >= 1 and . <= 65535) and
    (.reality.listen_port | type == "number" and . >= 1 and . <= 65535) and
    (.reality.path | type == "string" and test("^/[A-Za-z0-9._~/-]+$") and
      (contains("//") | not) and (contains("..") | not)) and
    (.reality.target | type == "string" and test("^[A-Za-z0-9.-]+:[0-9]{1,5}$")) and
    (.reality.server_name | type == "string" and test("^[A-Za-z0-9.-]+$")) and
    (.reality.short_id | type == "string" and test("^[0-9a-fA-F]{2,32}$")) and
    (.nginx.shared_tcp443 == false or
      (.reality.enabled == true and .reality.port == 443 and
       .reality.listen_port != 443)) and
    (.hysteria2.enabled | type == "boolean") and
    (.hysteria2.port | type == "number" and . >= 1 and . <= 65535) and
    (.hysteria2.shared_udp443 | type == "boolean") and
    (.hysteria2.shared_udp443 == false or
      (.hysteria2.enabled == true and .hysteria2.port == 443)) and
    (.hysteria2.obfs_password | type == "string" and length <= 512) and
    (.hysteria2.masquerade | type == "string") and
    (.hysteria2.enabled == false or
      (.hysteria2.masquerade | test("^https?://[^[:space:]]+$"))) and
    (.hysteria2.up_mbps | type == "number" and . >= 0 and . <= 100000) and
    (.hysteria2.down_mbps | type == "number" and . >= 0 and . <= 100000)
  ' <<<"$1" >/dev/null
}

prompt_worker_direct_config() {
  local bundle="$1" name default_address domain address is_baota=0
  local xhttp_enabled reality_enabled hy2_enabled shared_choice="n"
  local nginx_mode="disabled" tls_port=443 https_port=8443
  local auto_rebind=false cert="" key="" snippet=""
  local xhttp_public=8443 xhttp_listen=18000 xhttp_path xhttp_behind=false
  local reality_port=443 reality_listen=18443 reality_path reality_target
  local reality_sni reality_short
  local hy2_port=443 hy2_shared=true hy2_obfs hy2_masquerade hy2_up hy2_down
  local protocol_selection

  name="$(jq -r '.worker.name' <<<"$bundle")"
  default_address="$(jq -r '.worker.public_host // ""' <<<"$bundle")"
  [[ -n "$default_address" ]] || default_address="$(detect_public_ipv4)"
  if [[ -z "$default_address" || "$default_address" =~ ^[0-9.]+$ ]]; then
    domain="${name}.example.com"
  else
    domain="$default_address"
  fi

  printf '\n%s%s【从服务器设置：手机或电脑直接连接这台机器】%s\n' \
    "$C_BOLD" "$C_CYAN" "$C_RESET" >&2
  printf '这部分是从服务器自己的代理入口，不影响“主服务器 -> 从服务器”的中继线路。\n' >&2
  printf '没有域名时可先填写准备使用的域名；证书无效时脚本会生成自签证书。\n\n' >&2
  domain="$(prompt_hostname_value '从服务器入口域名（用于 TLS 证书和 SNI）' "$domain")"
  address="$(prompt_hostname_value '客户端实际连接的地址（通常填上面的域名，也可填公网 IP）' \
    "${default_address:-$domain}")"

  if [[ -x /www/server/nginx/sbin/nginx ]]; then
    is_baota=1
    printf '%s✓ 检测到宝塔，将复用宝塔 nginx，不安装第二套。%s\n' \
      "$C_GREEN" "$C_RESET" >&2
  fi

  protocol_selection="$(prompt_protocol_selection '2 3')"
  xhttp_enabled=n
  reality_enabled=n
  hy2_enabled=n
  [[ " $protocol_selection " != *" 1 "* ]] || xhttp_enabled=y
  [[ " $protocol_selection " != *" 2 "* ]] || reality_enabled=y
  [[ " $protocol_selection " != *" 3 "* ]] || hy2_enabled=y

  if [[ "$xhttp_enabled" == "y" || "$reality_enabled" == "y" ]]; then
    printf '\n%s【TCP 443 使用方式】%s\n' "$C_BOLD" "$C_RESET" >&2
    printf '选择共用后，客户端仍连接公网 TCP 443，脚本按域名和 Path 自动分流。\n' >&2
    shared_choice="$(prompt_bool '让网站、XHTTP 和 Reality 共用公网 TCP 443' y)"
  fi
  if [[ "$shared_choice" == "y" ]]; then
    if port_is_listening tcp 443 && ! port_is_nginx_owned tcp 443; then
      die "TCP 443 已被非 nginx 程序占用，无法配置共用"
    fi
    if (( is_baota )); then
      nginx_mode="snippet"
      snippet="/www/server/panel/vhost/nginx/extension/${domain}/etxr.conf"
      cert="/www/server/panel/vhost/cert/${domain}/fullchain.pem"
      key="/www/server/panel/vhost/cert/${domain}/privkey.pem"
      if [[ "$reality_enabled" == "y" ]]; then
        printf '下面是 nginx 在本机内部使用的端口，客户端不连接，也无需开放防火墙。\n' >&2
        https_port="$(prompt_port_checked '宝塔网站迁移后的本机 HTTPS TCP 端口' '8443' tcp)"
        printf '%s将先备份宝塔 HTTPS 配置，再把网站从公网 TCP 443 迁移到 127.0.0.1:%s；客户端访问网站仍使用 443。%s\n' \
          "$C_YELLOW" "$https_port" "$C_RESET" >&2
        menu_confirm "确认让 ETXR 自动备份并调整宝塔 HTTPS 监听" ||
          die "已取消 TCP 443 共用"
        auto_rebind=true
      fi
    else
      nginx_mode="standalone"
      cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
      key="/etc/letsencrypt/live/${domain}/privkey.pem"
      if [[ "$reality_enabled" == "y" ]]; then
        printf '下面是 nginx 在本机内部使用的端口，客户端不连接，也无需开放防火墙。\n' >&2
        https_port="$(prompt_port_checked '网站迁移后的 nginx 本机 HTTPS TCP 端口' '8443' tcp)"
      fi
      printf '%s未检测到宝塔，将安装标准 nginx 和 stream 模块。%s\n' \
        "$C_YELLOW" "$C_RESET" >&2
    fi
  elif [[ "$xhttp_enabled" == "y" ]]; then
    xhttp_public="$(prompt_port_checked 'XHTTP 公网 TLS TCP 端口（需在防火墙放行）' '8443' tcp)"
    xhttp_listen="$xhttp_public"
  fi

  xhttp_path="$(random_path)"
  if [[ "$xhttp_enabled" == "y" ]]; then
    if [[ "$shared_choice" == "y" ]]; then
      xhttp_public=443
      printf '下面是 nginx 转发到 Xray 的本机端口，客户端不连接，也无需开放防火墙。\n' >&2
      xhttp_listen="$(prompt_port_checked 'Xray XHTTP 本机接收 TCP 端口' '18000' tcp)"
      xhttp_behind=true
    fi
    xhttp_path="$(prompt_path_value 'XHTTP 连接 Path（纯随机，不包含节点名或协议名）' "$xhttp_path")"
  fi

  reality_path="$(random_path)"
  reality_target="aod.itunes.apple.com:443"
  reality_sni="aod.itunes.apple.com"
  reality_short="$(random_hex 8)"
  if [[ "$reality_enabled" == "y" ]]; then
    if [[ "$shared_choice" == "y" ]]; then
      reality_port=443
      printf '下面是 TCP 443 分流后转给 Xray 的本机端口，客户端不连接，也无需开放防火墙。\n' >&2
      reality_listen="$(prompt_port_checked 'Xray Reality 本机接收 TCP 端口' '18443' tcp)"
    else
      reality_port="$(prompt_port_checked 'Reality 公网 TCP 端口（需在防火墙放行）' \
        "$([[ "$xhttp_enabled" == "y" ]] && printf '18443' || printf '443')")"
      reality_listen="$reality_port"
    fi
    reality_path="$(prompt_path_value 'Reality 的 XHTTP 连接 Path（纯随机，不包含节点名或协议名）' "$reality_path")"
    reality_target="$(prompt_target_value 'Reality 握手转发目标（域名:443）' "$reality_target")"
    reality_sni="$(prompt_hostname_value 'Reality 客户端填写的伪装域名（SNI）' \
      "${reality_target%%:*}")"
    reality_short="$(prompt_value 'Reality Short ID（直接回车使用随机值）' "$reality_short")"
    [[ "$reality_short" =~ ^[0-9a-fA-F]{2,32}$ ]] ||
      die "Reality Short ID 必须是 2 到 32 位十六进制字符"
  fi

  hy2_obfs=""
  hy2_masquerade="https://${domain}"
  hy2_up=0
  hy2_down=0
  if [[ "$hy2_enabled" == "y" ]]; then
    hy2_obfs="$(random_password)"
    printf '\n%s【Hysteria2 公网 UDP 端口】%s\n' "$C_BOLD" "$C_RESET" >&2
    printf '网站 HTTPS 使用 TCP，Hysteria2 使用 UDP；两者都可使用数字 443。\n' >&2
    if [[ "$(prompt_bool '让 Hysteria2 使用公网 UDP 443' y)" == "y" ]] &&
       confirm_hy2_udp443_share; then
      hy2_port=443
      hy2_shared=true
    else
      hy2_port="$(prompt_port_checked 'Hysteria2 公网 UDP 端口（需在防火墙放行 UDP）' '28443' udp)"
      hy2_shared=false
    fi
    hy2_obfs="$(prompt_secret_default 'Hysteria2 混淆密码（客户端必须填写相同密码）' "$hy2_obfs")"
    hy2_masquerade="$(prompt_url_value 'Hysteria2 伪装网站 URL（需要包含 https://）' "$hy2_masquerade")"
    printf '下面是整条 Hysteria2 入站的带宽参数，不是单用户限速；0 表示不设置。\n' >&2
    hy2_up="$(prompt_mbps 'Hysteria2 总上传带宽 Mbps' '0')"
    hy2_down="$(prompt_mbps 'Hysteria2 总下载带宽 Mbps' '0')"
  else
    hy2_port=28443
    hy2_shared=false
  fi

  if [[ "$nginx_mode" != "disabled" || "$hy2_enabled" == "y" ||
        "$xhttp_enabled" == "y" ]]; then
    if [[ -z "$cert" ]]; then
      cert="${RUNTIME_DIR}/certs/${name}/fullchain.pem"
      key="${RUNTIME_DIR}/certs/${name}/privkey.pem"
    fi
    printf '\n%s【TLS 证书文件】%s\n' "$C_BOLD" "$C_RESET" >&2
    printf "已有宝塔或 Let's Encrypt 证书可直接回车；文件无效时会自动生成自签证书。\n" >&2
    cert="$(prompt_value '证书完整链文件路径（fullchain.pem）' "$cert")"
    key="$(prompt_value '证书私钥文件路径（privkey.pem）' "$key")"
  fi

  printf '\n%s【从服务器客户端入口摘要】%s\n' "$C_BOLD" "$C_RESET" >&2
  printf '客户端连接地址：%s\n' "$address" >&2
  if [[ "$xhttp_enabled" == "y" ]]; then
    printf 'XHTTP + TLS：已启用，公网 TCP %s，Path %s\n' \
      "$xhttp_public" "$xhttp_path" >&2
  else
    printf 'XHTTP + TLS：未启用\n' >&2
  fi
  if [[ "$reality_enabled" == "y" ]]; then
    printf 'Reality + XHTTP：已启用，公网 TCP %s，SNI %s\n' \
      "$reality_port" "$reality_sni" >&2
  else
    printf 'Reality + XHTTP：未启用\n' >&2
  fi
  if [[ "$hy2_enabled" == "y" ]]; then
    printf 'Hysteria2：已启用，公网 UDP %s\n' "$hy2_port" >&2
  else
    printf 'Hysteria2：未启用\n' >&2
  fi
  printf '提示：TCP 和 UDP 是不同协议；TCP 443 与 UDP 443 可以同时使用。\n' >&2

  WORKER_DIRECT_CONFIG="$(jq -n \
    --arg domain "$domain" --arg address "$address" \
    --arg mode "$nginx_mode" --arg cert "$cert" --arg key "$key" \
    --arg snippet "$snippet" --argjson tls_port "$tls_port" \
    --argjson https_port "$https_port" \
    --argjson shared "$([[ "$shared_choice" == "y" && "$reality_enabled" == "y" ]] && printf true || printf false)" \
    --argjson auto_rebind "$auto_rebind" \
    --argjson xhttp_enabled "$([[ "$xhttp_enabled" == "y" ]] && printf true || printf false)" \
    --argjson xhttp_public "$xhttp_public" --argjson xhttp_listen "$xhttp_listen" \
    --arg xhttp_path "$xhttp_path" --argjson xhttp_behind "$xhttp_behind" \
    --argjson reality_enabled "$([[ "$reality_enabled" == "y" ]] && printf true || printf false)" \
    --argjson reality_port "$reality_port" --argjson reality_listen "$reality_listen" \
    --arg reality_path "$reality_path" --arg reality_target "$reality_target" \
    --arg reality_sni "$reality_sni" --arg reality_short "$reality_short" \
    --argjson hy2_enabled "$([[ "$hy2_enabled" == "y" ]] && printf true || printf false)" \
    --argjson hy2_port "$hy2_port" --argjson hy2_shared "$hy2_shared" \
    --arg hy2_obfs "$hy2_obfs" --arg hy2_masquerade "$hy2_masquerade" \
    --argjson hy2_up "$hy2_up" --argjson hy2_down "$hy2_down" '
    {
      domain: $domain,
      address: $address,
      nginx: {
        mode: $mode,
        tls_port: $tls_port,
        https_listen_port: $https_port,
        shared_tcp443: $shared,
        auto_rebind_https: $auto_rebind,
        certificate: $cert,
        certificate_key: $key,
        snippet_path: $snippet
      },
      xhttp: {
        enabled: $xhttp_enabled,
        public_port: $xhttp_public,
        listen_port: $xhttp_listen,
        path: $xhttp_path,
        behind_nginx: $xhttp_behind
      },
      reality: {
        enabled: $reality_enabled,
        port: $reality_port,
        listen_port: $reality_listen,
        path: $reality_path,
        target: $reality_target,
        server_name: $reality_sni,
        short_id: $reality_short
      },
      hysteria2: {
        enabled: $hy2_enabled,
        port: $hy2_port,
        shared_udp443: $hy2_shared,
        obfs_password: $hy2_obfs,
        masquerade: $hy2_masquerade,
        up_mbps: $hy2_up,
        down_mbps: $hy2_down
      }
    }
  ')"
  validate_worker_direct_config "$WORKER_DIRECT_CONFIG" ||
    die "从服务器独立入口配置校验失败"
}

cmd_pair_join() {
  local pairing_id="" trusted_fingerprint="" prepare_only=0
  local configure_direct=0 direct_config_file="" direct_config=""
  while (($#)); do
    case "$1" in
      --prepare-only) prepare_only=1; shift ;;
      --configure-direct) configure_direct=1; shift ;;
      --direct-config-file) direct_config_file="${2:-}"; shift 2 ;;
      --fingerprint) trusted_fingerprint="${2:-}"; shift 2 ;;
      --help)
        cat <<'EOF'
Usage:
  etxr pair join [--prepare-only] --fingerprint SHA256_PREFIX PAIRING_ID
  etxr pair join --configure-direct --fingerprint SHA256_PREFIX PAIRING_ID
  etxr pair join --direct-config-file FILE --fingerprint SHA256_PREFIX PAIRING_ID

--configure-direct makes the worker ask for its own XHTTP, Reality, Hysteria2,
certificate, Path, and TCP/UDP 443 settings after the Pair ID is verified.
EOF
        return ;;
      *)
        [[ -z "$pairing_id" ]] || die "Only one pairing ID is allowed"
        pairing_id="$1"
        shift ;;
    esac
  done
  [[ -n "$pairing_id" ]] || die "Usage: etxr pair join PAIRING_ID"
  (( ! configure_direct || ${#direct_config_file} == 0 )) ||
    die "--configure-direct and --direct-config-file cannot be used together"
  [[ "$trusted_fingerprint" =~ ^[0-9a-fA-F]{32}$ ]] ||
    die "必须提供主服务器显示的 32 位 Pair 签名指纹"
  ensure_pair_join_tools
  need_jq
  need_cmd openssl
  need_cmd gzip
  need_cmd base64
  need_cmd sha256sum
  local bundle now name domain address cert="" key="" cert_info
  local nginx_mode components="xray,easytier" local_direct=0
  local certificate_insecure=false needs_certificate=false
  local reality_keys="" reality_private="" reality_public=""
  bundle="$(pair_decode "$pairing_id" "$trusted_fingerprint")"
  validate_pair_bundle "$bundle" ||
    die "Pair ID 字段校验失败，未安装软件、未覆盖现有状态"
  now="$(date +%s)"
  (( now <= $(jq -r '.expires_at' <<<"$bundle") )) || die "配对 ID 已过期，请在主服务器重新生成"
  name="$(jq -r '.worker.name' <<<"$bundle")"

  if [[ -n "$direct_config_file" ]]; then
    [[ -f "$direct_config_file" && -r "$direct_config_file" ]] ||
      die "从服务器协议配置文件不存在或不可读"
    (( $(wc -c <"$direct_config_file") <= 65536 )) ||
      die "从服务器协议配置文件超过 64 KiB"
    direct_config="$(jq -ce . "$direct_config_file")" ||
      die "从服务器协议配置文件不是有效 JSON"
    local_direct=1
  elif (( configure_direct )); then
    prompt_worker_direct_config "$bundle"
    direct_config="$WORKER_DIRECT_CONFIG"
    local_direct=1
  else
    direct_config="$(bundle_worker_direct_config "$bundle")"
  fi
  validate_worker_direct_config "$direct_config" ||
    die "从服务器协议配置字段校验失败，未安装软件、未覆盖现有状态"

  domain="$(jq -r '.domain' <<<"$direct_config")"
  address="$(jq -r '.address' <<<"$direct_config")"
  nginx_mode="$(jq -r '.nginx.mode' <<<"$direct_config")"
  valid_hostname "$domain" || die "从服务器域名无效"
  valid_hostname "$address" || die "从服务器客户端连接地址无效"

  jq -e --argjson c "$direct_config" '
    [
      .relay.private_port,
      (if .relay.public_enabled then .relay.listen_port else empty end),
      (if $c.xhttp.enabled then $c.xhttp.listen_port else empty end),
      (if $c.reality.enabled then $c.reality.listen_port else empty end)
    ] | length == (unique | length)
  ' <<<"$bundle" >/dev/null ||
    die "主从中继、XHTTP 或 Reality 的本地 TCP 监听端口重复"

  if (( ! prepare_only )); then
    need_root
    # Only basic validation tools are installed before this point. Xray,
    # EasyTier, sing-box, and nginx are installed only after the signed bundle
    # and the complete worker-local protocol configuration pass validation.
    [[ "$(jq -r '.hysteria2.enabled' <<<"$direct_config")" != "true" ]] ||
      components+=",sing-box"
    [[ "$nginx_mode" != "standalone" ]] || components+=",nginx"
    cmd_install --components "$components"
  fi

  if [[ "$nginx_mode" != "disabled" ||
        "$(jq -r '.xhttp.enabled' <<<"$direct_config")" == "true" ||
        "$(jq -r '.hysteria2.enabled' <<<"$direct_config")" == "true" ]]; then
    needs_certificate=true
  fi
  cert="$(jq -r '.nginx.certificate' <<<"$direct_config")"
  key="$(jq -r '.nginx.certificate_key' <<<"$direct_config")"
  if [[ "$needs_certificate" == "true" ]]; then
    if ! tls_certificate_is_usable "$cert" "$key"; then
      [[ -z "$cert" && -z "$key" ]] ||
        warn "指定证书不可用、已过期或与私钥不匹配，将改用自动生成的自签证书"
      cert_info="$(generate_self_signed_cert "$name" "$domain")"
      cert="$(sed -n '1p' <<<"$cert_info")"
      key="$(sed -n '2p' <<<"$cert_info")"
      certificate_insecure=true
    elif ! tls_certificate_matches_name "$cert" "$domain"; then
      warn "证书不包含域名 $domain，订阅将自动启用跳过证书名称校验"
      certificate_insecure=true
    fi
    direct_config="$(jq -c --arg cert "$cert" --arg key "$key" \
      '.nginx.certificate = $cert | .nginx.certificate_key = $key' \
      <<<"$direct_config")"
  fi
  if [[ "$(jq -r '.reality.enabled' <<<"$direct_config")" == "true" ]]; then
    if (( local_direct )); then
      reality_keys="$("$XRAY_BIN" x25519)"
      reality_private="$(awk -F': ' '/^PrivateKey:/ {print $2; exit}' <<<"$reality_keys")"
      reality_public="$(awk -F': ' '/^(Password|PublicKey)/ {print $2; exit}' <<<"$reality_keys")"
    else
      reality_private="$(jq -r '.direct.reality.private_key // ""' <<<"$bundle")"
      reality_public="$(jq -r '.direct.reality.public_key // ""' <<<"$bundle")"
    fi
    [[ -n "$reality_private" && -n "$reality_public" ]] ||
      die "无法解析从服务器本机生成的 Reality x25519 密钥"
  fi

  FORCE=1
  cmd_init --name "$name" --role exit --domain "$domain" --address "$address" \
    --nginx-mode "$nginx_mode" \
    --tls-port "$(jq -r '.nginx.tls_port' <<<"$direct_config")" \
    --nginx-https-listen-port "$(jq -r '.nginx.https_listen_port' <<<"$direct_config")" \
    --nginx-shared-tcp443 "$(jq -r '.nginx.shared_tcp443' <<<"$direct_config")" \
    --nginx-auto-rebind-https "$(jq -r '.nginx.auto_rebind_https' <<<"$direct_config")" \
    --snippet "$(jq -r '.nginx.snippet_path' <<<"$direct_config")" \
    --cert "$cert" --key "$key"
  FORCE=0
  local private_relay public_relay='[]' xhttp_routes='[]' reality_inbounds='[]'
  local worker_users
  private_relay="$(jq -c '{
    name: (.worker.name + "-private"),
    listen: .worker.easytier_ip,
    port: .relay.private_port,
    public: false,
    allowed_source: "",
    uuid: .relay.uuid,
    decryption: .relay.decryption,
    flow: .relay.flow
  }' <<<"$bundle")"
  if [[ "$(jq -r '.relay.public_enabled' <<<"$bundle")" == "true" ]]; then
    public_relay="$(jq -c '[{
      name: (.worker.name + "-public"),
      listen: "0.0.0.0",
      port: (.relay.listen_port // .relay.public_port),
      public: true,
      allowed_source: .master.source_cidr,
      uuid: .relay.uuid,
      decryption: .relay.decryption,
      flow: .relay.flow
    }]' <<<"$bundle")"
  fi
  if [[ "$(jq -r '.xhttp.enabled' <<<"$direct_config")" == "true" ]]; then
    xhttp_routes="$(jq -nc \
      --arg name "$name" --arg cert "$cert" --arg key "$key" \
      --argjson config "$direct_config" \
      --argjson insecure "$certificate_insecure" '
      $config.xhttp as $x |
      [{
      name: ($name + "-xhttp"),
      listen: (if $x.behind_nginx then "127.0.0.1" else "0.0.0.0" end),
      port: $x.listen_port,
      public_port: $x.public_port,
      path: $x.path,
      target: "direct",
      profile: "plain",
      host: "",
      decryption: "none",
      client_encryption: "none",
      flow: "",
      direct: true,
      security: (if $x.behind_nginx then "none" else "tls" end),
      certificate: (if $x.behind_nginx then "" else $cert end),
      certificate_key: (if $x.behind_nginx then "" else $key end),
      allow_insecure: $insecure
    }]')"
  fi
  if [[ "$(jq -r '.reality.enabled' <<<"$direct_config")" == "true" ]]; then
    reality_inbounds="$(jq -nc \
      --arg private "$reality_private" --arg public "$reality_public" \
      --argjson config "$direct_config" '
      $config.reality as $r |
      [{
        name: "direct",
        listen: (if $config.nginx.shared_tcp443 then "127.0.0.1" else "0.0.0.0" end),
        port: $r.port,
        listen_port: $r.listen_port,
        path: $r.path,
        target: $r.target,
        server_names: [$r.server_name],
        private_key: $private,
        public_key: $public,
        short_ids: [$r.short_id]
      }]')"
  fi
  worker_users="$(jq -c --arg prefix "$(sha1_prefix admin)" \
    --arg token "$(random_hex 20)" '
    if ((.users // []) | length) > 0 then
      .users
    else [{
      name: "admin",
      uuid: .direct.user_uuid,
      hy2_password: .direct.hysteria2.password,
      enabled: true,
      expires_at: null,
      routes: ["*"],
      enabled_nodes: ["*"],
      subscription_prefix: $prefix,
      subscription_token: $token,
      speed_limit: {up_mbps: 0, down_mbps: 0},
      usage_epoch: ""
    }] end
  ' <<<"$bundle")"

  state_update '
    .easytier = {
      enabled: true,
      ipv4: $et_ip,
      network_name: $et_name,
      network_secret: $et_secret,
      peer: ($master + ":" + ($et_port | tostring)),
      tcp_port: $et_port
    } |
    .xray.relay_inbounds = ([$private] + $public) |
    .xray.routes = $xhttp_routes |
    .xray.reality_inbounds = $reality_inbounds |
    .hysteria2.enabled = $hy2_enabled |
    .hysteria2.port = $hy2_port |
    .hysteria2.shared_udp443 = $hy2_shared_udp443 |
    .hysteria2.up_mbps = $hy2_up |
    .hysteria2.down_mbps = $hy2_down |
    .hysteria2.obfs = "salamander" |
    .hysteria2.obfs_password = $hy2_obfs |
    .hysteria2.masquerade = $hy2_masquerade |
    .hysteria2.certificate = $cert |
    .hysteria2.certificate_key = $key |
    .hysteria2.insecure = $certificate_insecure |
    .control = {
      enabled: false,
      base_path: "",
      listen: "127.0.0.1",
      port: 18180,
      agent: {
        enabled: true,
        base_url: $control_url,
        node_id: $control_node,
        token: $control_token
      }
    } |
    .users = $users
  ' --arg et_ip "$(jq -r '.worker.easytier_ip' <<<"$bundle")" \
    --arg et_name "$(jq -r '.easytier.network_name' <<<"$bundle")" \
    --arg et_secret "$(jq -r '.easytier.network_secret' <<<"$bundle")" \
    --arg master "$(jq -r '.master.address' <<<"$bundle")" \
    --argjson et_port "$(jq -r '.master.tcp_port' <<<"$bundle")" \
    --argjson private "$private_relay" --argjson public "$public_relay" \
    --argjson xhttp_routes "$xhttp_routes" \
    --argjson reality_inbounds "$reality_inbounds" \
    --argjson hy2_enabled "$(jq -r '.hysteria2.enabled' <<<"$direct_config")" \
    --argjson hy2_port "$(jq -r '.hysteria2.port' <<<"$direct_config")" \
    --argjson hy2_shared_udp443 "$(jq -r '.hysteria2.shared_udp443' <<<"$direct_config")" \
    --argjson hy2_up "$(jq -r '.hysteria2.up_mbps' <<<"$direct_config")" \
    --argjson hy2_down "$(jq -r '.hysteria2.down_mbps' <<<"$direct_config")" \
    --arg hy2_obfs "$(jq -r '.hysteria2.obfs_password' <<<"$direct_config")" \
    --arg hy2_masquerade "$(jq -r '.hysteria2.masquerade' <<<"$direct_config")" \
    --arg control_url "$(jq -r '.control.base_url' <<<"$bundle")" \
    --arg control_node "$(jq -r '.control.node_id' <<<"$bundle")" \
    --arg control_token "$(jq -r '.control.token' <<<"$bundle")" \
    --arg cert "$cert" --arg key "$key" \
    --argjson certificate_insecure "$certificate_insecure" \
    --argjson users "$worker_users"

  if (( prepare_only )); then
    cmd_render
    printf '\n%s从服务器 %s 配置已生成但未安装服务。%s\n' "$C_GREEN" "$name" "$C_RESET"
  else
    cmd_apply
    printf '\n%s从服务器 %s 已完成一键安装。%s\n' "$C_GREEN" "$name" "$C_RESET"
  fi
  printf 'EasyTier：%s -> %s:%s\n' \
    "$(jq -r '.worker.easytier_ip' <<<"$bundle")" \
    "$(jq -r '.master.address' <<<"$bundle")" \
    "$(jq -r '.master.tcp_port' <<<"$bundle")"
  printf '订阅由主服务器统一生成；这台从服务器不提供订阅地址。\n'
}

pair_node_status() {
  local name="$1" expires_at="${2:-0}" now remaining report_status
  if [[ -f "$CONTROL_DIR/reports/${name}.json" ]]; then
    report_status="$(jq -r '.status // "已连接"' \
      "$CONTROL_DIR/reports/${name}.json" 2>/dev/null || printf '已连接')"
    case "$report_status" in
      connected|applied|ok|success) printf '已连接' ;;
      *) printf '已连接（%s）' "$report_status" ;;
    esac
    return
  fi
  if [[ ! "$expires_at" =~ ^[0-9]+$ ]]; then
    printf 'Pair 状态未知'
    return
  fi
  now="$(date +%s)"
  if (( 10#$expires_at <= now )); then
    printf 'Pair ID 已过期'
  elif [[ ! -s "$RUNTIME_DIR/pairs/${name}.id" ]]; then
    printf 'Pair ID 文件缺失'
  else
    remaining="$(( (10#$expires_at - now + 59) / 60 ))"
    printf '等待连接（剩余约 %s 分钟）' "$remaining"
  fi
}

cmd_pair_renew() {
  local name="${1:-}" expires_minutes=30 expires_at pair_file pairing_id
  local bundle renewed fingerprint
  [[ -n "$name" ]] || die "Usage: etxr pair renew WORKER [--expires-minutes 30]"
  shift || true
  while (($#)); do
    case "$1" in
      --expires-minutes) expires_minutes="$2"; shift 2 ;;
      --help)
        echo "Usage: etxr pair renew WORKER [--expires-minutes 30]"
        return
        ;;
      *) die "Unknown pair renew option: $1" ;;
    esac
  done
  valid_name "$name" || die "Invalid worker name"
  [[ "$expires_minutes" =~ ^[0-9]+$ ]] ||
    die "有效期必须是整数分钟"
  (( 10#$expires_minutes >= 1 && 10#$expires_minutes <= 525600 )) ||
    die "有效期必须是 1 到 525600 分钟"
  expires_minutes="$((10#$expires_minutes))"
  require_state
  ensure_control_state
  [[ "$(jq -r '.node.role' "$STATE_FILE")" != "exit" ]] ||
    die "只能在主服务器续发 Pair ID"
  jq -e --arg name "$name" \
    '.paired_nodes[]? | select(.name == $name)' "$STATE_FILE" >/dev/null ||
    die "未找到从服务器：$name"
  pair_file="$RUNTIME_DIR/pairs/${name}.id"
  [[ -s "$pair_file" ]] ||
    die "原 Pair ID 文件不存在；请删除该从服务器后重新添加"
  (( $(wc -c <"$pair_file") <= PAIR_ID_MAX_BYTES + 1 )) ||
    die "原 Pair ID 文件超过大小限制"
  pairing_id="$(tr -d '\r\n' <"$pair_file")"
  fingerprint="$(pair_public_fingerprint)"
  bundle="$(pair_decode "$pairing_id" "$fingerprint")"
  validate_pair_bundle "$bundle" ||
    die "原 Pair ID 内容无效；请删除该从服务器后重新添加"
  [[ "$(jq -r '.worker.name' <<<"$bundle")" == "$name" ]] ||
    die "原 Pair ID 与从服务器名称不匹配"
  expires_at="$(( $(date +%s) + expires_minutes * 60 ))"
  renewed="$(jq -c --argjson expires "$expires_at" \
    --argjson users "$(jq '.users' "$STATE_FILE")" \
    '.expires_at = $expires | .users = $users' <<<"$bundle")"
  validate_pair_bundle "$renewed" || die "续发后的 Pair ID 内容校验失败"
  pairing_id="$(pair_encode "$renewed")"
  state_update '
    .paired_nodes |= map(
      if .name == $name then
        .expires_at = $expires |
        .pair_issued_at = $issued
      else . end
    )
  ' --arg name "$name" --argjson expires "$expires_at" \
    --arg issued "$(date -u +%FT%TZ)"
  printf '%s\n' "$pairing_id" | atomic_write "$pair_file"
  printf '\n%s新的 Pair ID（旧 ID 不会被延长）：%s\n\n%s\n\n' \
    "$C_GREEN" "$C_RESET" "$pairing_id"
  printf 'Pair 签名指纹：%s\n' "$fingerprint"
  printf '新的加入有效期：%s 分钟，到期时间约为 %s\n' \
    "$expires_minutes" "$(date -d "@$expires_at" '+%F %T %Z')"
  printf '线路、端口、Path、UUID 和 EasyTier IP 均保持不变。\n'
}

cmd_pair_list() {
  require_state
  local node name expires status public_host
  printf '从服务器\tEasyTier IP\t公网地址\t主服务器 Path\tPair/连接状态\n'
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    name="$(jq -r '.name' <<<"$node")"
    expires="$(jq -r '.expires_at // 0' <<<"$node")"
    public_host="$(jq -r '.public_host // ""' <<<"$node")"
    status="$(pair_node_status "$name" "$expires")"
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$name" \
      "$(jq -r '.easytier_ip' <<<"$node")" \
      "${public_host:--}" \
      "$(jq -r '.route_path' <<<"$node")" \
      "$status"
  done < <(jq -c '(.paired_nodes // [])[]' "$STATE_FILE")
}

cmd_pair_remove() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "Worker name required"
  valid_name "$name" || die "Invalid worker name"
  require_state
  state_update '
    .paired_nodes |= map(select(.name != $name)) |
    .xray.routes |= map(select(.name != $name)) |
    .xray.exits |= map(select(.name != $name))
  ' --arg name "$name"
  rm -f "$RUNTIME_DIR/pairs/${name}.id"
  rm -f "$CONTROL_DIR/nodes/${name}.json" "$CONTROL_DIR/reports/${name}.json"
  log "Removed paired worker $name"
}

cmd_control_apply() {
  local prepare_only=0 payload bundle
  if [[ "${1:-}" == "--prepare-only" ]]; then
    prepare_only=1
    shift
  fi
  (( prepare_only )) || need_root
  require_state
  [[ "$(jq -r '.node.role' "$STATE_FILE")" == "exit" ]] ||
    die "control apply 只允许在从服务器执行"
  payload="$(cat)"
  bundle="$(jq -c '
    if type == "array" then {users: ., domain_audit: null}
    elif type == "object" then .
    else error("invalid control payload") end
  ' <<<"$payload")" || die "Invalid WSS configuration payload"
  jq -e '
    type == "object" and
    (.users | type == "array" and
      (map(.name) | length == (unique | length)) and
      (map(.uuid) | length == (unique | length)) and
      (map(.subscription_token) | length == (unique | length)) and
      all(.[];
        (.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) and
        (.uuid | type == "string" and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$")) and
        (.hy2_password | type == "string" and length <= 512 and (test("[\u0000-\u001f\u007f]") | not)) and
        (.enabled | type == "boolean") and
        (.expires_at == null or (.expires_at | type == "string")) and
        (.routes | type == "array" and all(.[]; type == "string" and test("^[A-Za-z0-9._-]{1,64}$|^\\*$"))) and
        ((.enabled_nodes // ["*"]) | type == "array" and
          length == (unique | length) and
          all(.[]; type == "string" and
            test("^\\*$|^[A-Za-z0-9][A-Za-z0-9._-]{0,63}/((xhttp|reality)/[A-Za-z0-9][A-Za-z0-9._-]{0,63}|hy2)$"))) and
        (.subscription_prefix | type == "string" and test("^[0-9a-fA-F]{8}$")) and
        (.subscription_token | type == "string" and test("^[0-9a-fA-F]{40}$")) and
        ((.speed_limit // {up_mbps: 0, down_mbps: 0}) |
          type == "object" and
          (.up_mbps | type == "number" and floor == . and . >= 0 and . <= 100000) and
          (.down_mbps | type == "number" and floor == . and . >= 0 and . <= 100000)) and
        ((.usage_epoch // "") | type == "string" and length <= 128) and
        ((.domain_epoch // "") | type == "string" and length <= 128)
      )) and
    (.domain_audit == null or (
      (.domain_audit | type == "object") and
      (.domain_audit.enabled | type == "boolean") and
      (.domain_audit.retention_days | type == "number" and floor == . and . >= 1 and . <= 365) and
      (.domain_audit.max_domains_per_user | type == "number" and floor == . and . >= 10 and . <= 5000)
    ))
  ' <<<"$bundle" >/dev/null || die "Invalid WSS configuration payload"
  state_update '
    .users = $bundle.users |
    .domain_audit = (
      if $bundle.domain_audit == null then
        ((.domain_audit // {}) + {
          enabled: (.domain_audit.enabled // false),
          retention_days: (.domain_audit.retention_days // 30),
          max_domains_per_user: (.domain_audit.max_domains_per_user // 500)
        })
      else $bundle.domain_audit end
    )
  ' --argjson bundle "$bundle"
  if (( prepare_only )); then
    cmd_render
  else
    cmd_apply
  fi
  log "WSS configuration applied for $(jq '.users | length' <<<"$bundle") users"
}

cmd_control_status() {
  require_state
  local role node name desired report expires pair_status
  role="$(jq -r '.node.role' "$STATE_FILE")"
  if [[ "$role" == "exit" ]]; then
    printf 'Agent：%s\n' "$(systemctl is-active etxr-agent.service 2>/dev/null || true)"
    printf '当前版本：%s\n' "$(cat "$RUNTIME_DIR/control-version" 2>/dev/null || printf '-')"
    printf '控制地址：%s\n' "$(jq -r '.control.agent.base_url' "$STATE_FILE")"
    return
  fi
  render_control_desired
  printf '从服务器\t目标版本\t已应用版本\t状态\t最后回报\n'
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    name="$(jq -r '.name' <<<"$node")"
    desired="$(jq -r '.version' "$CONTROL_DIR/nodes/${name}.json")"
    report="$CONTROL_DIR/reports/${name}.json"
    if [[ -f "$report" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\n' \
        "$name" "${desired:0:12}" \
        "$(jq -r '.version // "-"' "$report" | cut -c1-12)" \
        "$(jq -r '.status // "-"' "$report")" \
        "$(jq -r '.received_at // "-"' "$report")"
    else
      expires="$(jq -r '.expires_at // 0' <<<"$node")"
      pair_status="$(pair_node_status "$name" "$expires")"
      printf '%s\t%s\t-\t%s\t-\n' "$name" "${desired:0:12}" "$pair_status"
    fi
  done < <(jq -c '(.paired_nodes // [])[]' "$STATE_FILE")
}

cmd_control() {
  local action="${1:-}"; shift || true
  case "$action" in
    apply) cmd_control_apply "$@" ;;
    status) cmd_control_status ;;
    helper) install_control_helper ;;
    data-helper) install_data_helper ;;
    *) die "Usage: etxr control apply|status" ;;
  esac
}

cmd_cluster() {
  local action="${1:-}"; shift || true
  case "$action" in
    master-init) cmd_cluster_master_init "$@" ;;
    *) die "Usage: etxr cluster master-init" ;;
  esac
}

cmd_pair() {
  local action="${1:-}"; shift || true
  case "$action" in
    create) cmd_pair_create "$@" ;;
    join) cmd_pair_join "$@" ;;
    renew) cmd_pair_renew "$@" ;;
    list) cmd_pair_list ;;
    remove) cmd_pair_remove "$@" ;;
    decode)
      local fingerprint="" id="${1:-}"
      [[ "$id" != "--fingerprint" ]] || {
        fingerprint="${2:-}"
        id="${3:-}"
      }
      pair_decode "$id" "$fingerprint" | jq .
      ;;
    *) die "Usage: etxr pair create|join|renew|list|remove" ;;
  esac
}

cmd_subscription() {
  local name="${1:-}"; [[ -n "$name" ]] || die "用法：etxr subscription 用户名"
  require_state
  [[ "$(jq -r '.node.role' "$STATE_FILE")" != "exit" ]] ||
    die "从服务器不生成订阅，请到主服务器查看"
  local user token prefix domain
  user="$(active_user_json "$name")" || die "用户不存在、已暂停或已过期：$name"
  subscription_plain "$name"
  token="$(jq -r '.subscription_token' <<<"$user")"
  prefix="$(jq -r '.subscription_prefix' <<<"$user")"
  domain="$(jq -r '.node.domain' "$STATE_FILE")"
  if [[ "$(jq -r '.nginx.mode' "$STATE_FILE")" != "disabled" ]]; then
    local port suffix=""
    port="$(jq -r '.nginx.tls_port' "$STATE_FILE")"
    [[ "$port" == "443" ]] || suffix=":${port}"
    printf '\n订阅链接：https://%s%s/%s/%s\n' "$domain" "$suffix" "$prefix" "$token"
  fi
}

cmd_subscriptions_snapshot() {
  require_state
  subscription_entry_from_state
}

cmd_subscriptions_refresh() {
  require_state
  need_root
  [[ "$(jq -r '.node.role' "$STATE_FILE")" != "exit" ]] ||
    die "从服务器不生成订阅，请到主服务器刷新"
  local parent staging previous subscription_group=www-data
  parent="$(dirname "$SUBSCRIPTION_DIR")"
  [[ -n "$SUBSCRIPTION_DIR" && "$SUBSCRIPTION_DIR" != "/" ]] ||
    die "Unsafe subscription directory"
  state_lock_acquire
  mkdir -p "$parent"
  staging="$(mktemp -d "$parent/.etxr-subscriptions.XXXXXX")"
  previous="$parent/.etxr-subscriptions-previous.$$"
  render_subscriptions "$staging"
  getent passwd www >/dev/null 2>&1 && subscription_group=www
  chown root:"$subscription_group" "$parent" "$staging"
  chmod 751 "$parent"
  chmod 750 "$staging"
  find "$staging" -mindepth 1 -maxdepth 1 -type f \
    -exec chown root:"$subscription_group" {} + \
    -exec chmod 640 {} +
  if [[ -e "$SUBSCRIPTION_DIR" ]]; then
    mv "$SUBSCRIPTION_DIR" "$previous"
  fi
  if ! mv "$staging" "$SUBSCRIPTION_DIR"; then
    [[ ! -e "$previous" ]] || mv "$previous" "$SUBSCRIPTION_DIR"
    rm -rf "$staging"
    state_lock_release
    die "刷新主服务器订阅失败，已恢复原订阅"
  fi
  rm -rf "$previous"
  state_lock_release
  log "主服务器订阅已合并最新从服务器入口"
}

cmd_subscriptions() {
  local action="${1:-}"; shift || true
  case "$action" in
    snapshot) cmd_subscriptions_snapshot "$@" ;;
    refresh) cmd_subscriptions_refresh "$@" ;;
    *) die "Usage: etxr subscriptions refresh|snapshot" ;;
  esac
}

cmd_client() {
  local name="${1:-}" route_name="" socks_port=10808 out=""
  [[ -n "$name" ]] || die "Usage: etxr client USER --route ROUTE [--socks-port 10808] [--out FILE]"
  shift || true
  while (($#)); do
    case "$1" in
      --route) route_name="$2"; shift 2 ;;
      --socks-port) socks_port="$2"; shift 2 ;;
      --out) out="$2"; shift 2 ;;
      --help)
        echo "Usage: etxr client USER --route ROUTE [--socks-port 10808] [--out FILE]"
        return ;;
      *) die "Unknown client option: $1" ;;
    esac
  done
  require_state
  [[ -n "$route_name" ]] || die "--route is required"
  valid_port "$socks_port" || die "Invalid SOCKS port"
  local user route domain address tls_port result
  user="$(active_user_json "$name")" || die "用户不存在、已暂停或已过期：$name"
  route="$(jq -ce --arg name "$route_name" '.xray.routes[] | select(.name == $name)' "$STATE_FILE")" ||
    die "Route not found: $route_name"
  jq -e --arg route "$route_name" '
    (.routes | index("*")) != null or (.routes | index($route)) != null
  ' <<<"$user" >/dev/null || die "User $name is not allowed on route $route_name"
  domain="$(jq -r '.node.domain' "$STATE_FILE")"
  address="$(jq -r '.node.address' "$STATE_FILE")"
  tls_port="$(jq -r '.nginx.tls_port' "$STATE_FILE")"

  result="$(jq -n \
    --argjson user "$user" --argjson route "$route" \
    --arg domain "$domain" --arg address "$address" \
    --argjson tls_port "$tls_port" --argjson socks_port "$socks_port" '
    {
      log: {loglevel: "warning"},
      inbounds: [{
        tag: "socks-in",
        listen: "127.0.0.1",
        port: $socks_port,
        protocol: "socks",
        settings: {udp: true}
      }],
      outbounds: [{
        tag: ("gateway-" + $route.name),
        protocol: "vless",
        settings: {
          vnext: [{
            address: $address,
            port: $tls_port,
            users: [{
              id: $user.uuid,
              encryption: ($route.client_encryption // "none"),
              level: 0
            } + (if ($route.flow // "") == "" then {} else {flow: $route.flow} end)]
          }]
        },
        streamSettings: {
          network: "xhttp",
          security: "tls",
          tlsSettings: {
            serverName: $domain,
            allowInsecure: false,
            alpn: ["h2"],
            fingerprint: "chrome"
          },
          xhttpSettings: {
            host: (if ($route.host // "") == "" then $domain else $route.host end),
            path: $route.path,
            mode: "auto",
            extra: {
              noGRPCHeader: false,
              scMaxEachPostBytes: 1000000,
              scMinPostsIntervalMs: 30,
              xPaddingBytes: "100-1000",
              xmux: {
                maxConcurrency: "16-32",
                maxConnections: 0,
                cMaxReuseTimes: "64-128",
                cMaxLifetimeMs: 0,
                hMaxRequestTimes: "800-900",
                hKeepAlivePeriod: 0
              }
            }
          },
          sockopt: {
            tcpFastOpen: true,
            tcpNoDelay: true
          }
        }
      }]
    }')"
  if [[ -n "$out" ]]; then
    printf '%s\n' "$result" | atomic_write "$out"
    log "Client config written to $out"
  else
    printf '%s\n' "$result"
  fi
}

cmd_status() {
  require_state
  jq '{
    node,
    nginx: {
      mode: .nginx.mode,
      tls_port: .nginx.tls_port,
      shared_tcp443: (.nginx.shared_tcp443 // false),
      https_listen_port: (.nginx.https_listen_port // .nginx.tls_port)
    },
    users: (.users | length),
    domain_audit: {
      enabled: (.domain_audit.enabled // false),
      retention_days: (.domain_audit.retention_days // 30),
      max_domains_per_user: (.domain_audit.max_domains_per_user // 500)
    },
    easytier: {
      enabled: (.easytier.enabled // false),
      ipv4: (.easytier.ipv4 // ""),
      endpoint: (.easytier.public_endpoint // ""),
      peer: (.easytier.peer // "")
    },
    paired_nodes: [(.paired_nodes // [])[] | {
      name, easytier_ip, public_host, route_path
    }],
    routes: [.xray.routes[] | {name,path,port,target,profile}],
    exits: [.xray.exits[] | {name,address,port,transport}],
    reality: [.xray.reality_inbounds[] |
      {name, public_port: .port, listen_port: (.listen_port // .port), path}],
    hysteria2: {
      enabled: .hysteria2.enabled,
      port: .hysteria2.port,
      shared_udp443: (.hysteria2.shared_udp443 // false)
    }
  }' "$STATE_FILE"
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl --no-pager --full status etxr-easytier.service 2>/dev/null | sed -n '1,8p' || true
  systemctl --no-pager --full status etxr-limiter.service 2>/dev/null | sed -n '1,8p' || true
  systemctl --no-pager --full status etxr-xray.service 2>/dev/null | sed -n '1,8p' || true
  systemctl --no-pager --full status etxr-sing-box.service 2>/dev/null | sed -n '1,8p' || true
  systemctl --no-pager --full status etxr-meter.service 2>/dev/null | sed -n '1,8p' || true
  systemctl --no-pager --full status etxr-domain-audit.service 2>/dev/null | sed -n '1,8p' || true
  systemctl --no-pager --full status etxr-control.service 2>/dev/null | sed -n '1,8p' || true
  systemctl --no-pager --full status etxr-agent.service 2>/dev/null | sed -n '1,8p' || true
}

menu_exec() {
  if ( "$@" ); then
    return 0
  else
    local rc=$?
    printf '%s操作失败，返回码：%s%s\n' "$C_RED" "$rc" "$C_RESET" >&2
    return "$rc"
  fi
}

menu_apply_prompt() {
  printf '\n%s正在自动保存并检查配置，请稍候……%s\n' "$C_CYAN" "$C_RESET"
  if menu_exec cmd_apply; then
    printf '%s✓ 已保存并生效，不需要再做其他操作。%s\n' "$C_GREEN" "$C_RESET"
  else
    printf '%s✗ 配置没有生效，旧服务仍会尽量保持不变。%s\n' "$C_RED" "$C_RESET"
    printf '请在主菜单选择“一键检查”，查看具体原因。\n'
    return 1
  fi
}

service_badge() {
  local service="$1" state
  state="$(systemctl is-active "$service" 2>/dev/null || true)"
  if [[ "$state" == "active" ]]; then
    printf '%s正常%s' "$C_GREEN" "$C_RESET"
  elif [[ "$state" == "inactive" ]]; then
    printf '%s已停止%s' "$C_YELLOW" "$C_RESET"
  else
    printf '%s异常%s' "$C_RED" "$C_RESET"
  fi
}

friendly_role() {
  case "$1" in
    gateway) printf '主服务器' ;;
    exit) printf '从服务器' ;;
    hybrid) printf '主从混合服务器' ;;
    *) printf '未初始化' ;;
  esac
}

menu_header() {
  clear_screen
  printf '%s%s╔════════════════════════════════════════════════════╗%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
  printf '%s%s║       ETXR 简易管理面板  v%-15s║%s\n' \
    "$C_BOLD" "$C_CYAN" "$VERSION" "$C_RESET"
  printf '%s%s╚════════════════════════════════════════════════════╝%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
  if [[ -f "$STATE_FILE" ]] && command -v jq >/dev/null 2>&1; then
    local node role domain users routes peers control_service
    node="$(jq -r '.node.name // "-"' "$STATE_FILE" 2>/dev/null || printf '-')"
    role="$(jq -r '.node.role // "-"' "$STATE_FILE" 2>/dev/null || printf '-')"
    domain="$(jq -r '.node.domain // "-"' "$STATE_FILE" 2>/dev/null || printf '-')"
    users="$(jq -r '.users | length' "$STATE_FILE" 2>/dev/null || printf '0')"
    routes="$(jq -r '.xray.routes | length' "$STATE_FILE" 2>/dev/null || printf '0')"
    peers="$(jq -r '(.paired_nodes // []) | length' "$STATE_FILE" 2>/dev/null || printf '0')"
    if [[ "$role" == "exit" ]]; then
      control_service="etxr-agent.service"
    else
      control_service="etxr-control.service"
    fi
    printf ' 当前机器：%s（%s）\n' "$node" "$(friendly_role "$role")"
    printf ' 连接域名：%s\n' "$domain"
    printf ' 运行状态：Xray [%s]  组网 [%s]  HY2 [%s]\n' \
      "$(service_badge etxr-xray.service)" \
      "$(service_badge etxr-easytier.service)" \
      "$(service_badge etxr-sing-box.service)"
    printf ' 配置下发：%s [%s]\n' \
      "$([[ "$role" == "exit" ]] && printf '接收端' || printf '主控端')" \
      "$(service_badge "$control_service")"
    printf ' 流量统计：[%s]  域名统计：%s\n' \
      "$(service_badge etxr-meter.service)" \
      "$([[ "$(jq -r '.domain_audit.enabled // false' "$STATE_FILE")" == "true" ]] && \
        service_badge etxr-domain-audit.service || printf '未启用')"
    printf ' 已有配置：%s 个用户 / %s 条线路 / %s 台从服务器\n' \
      "$users" "$routes" "$peers"
  else
    printf ' %s这台机器还没有安装，请选择下面的 1 或 2。%s\n' \
      "$C_YELLOW" "$C_RESET"
  fi
  printf '%s\n' '──────────────────────────────────────────────────────'
}

menu_quick_init() {
  clear_screen
  printf '%s%s【主服务器安装向导】%s\n\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
  printf '每一项都提供默认值，直接回车即可使用；填写后会立即检查格式。\n'
  printf '本机端口会检查是否已占用，宝塔 nginx 共用的 HTTPS 端口除外。\n\n'
  local is_baota=0 install_components="xray,sing-box,easytier,nginx"
  if [[ -x /www/server/nginx/sbin/nginx ]]; then
    is_baota=1
    install_components="xray,sing-box,easytier"
    printf '%s✓ 已检测到宝塔，将复用宝塔 nginx 和证书。%s\n' "$C_GREEN" "$C_RESET"
    printf '  不会修改其他网站，也不会安装第二套 nginx。\n'
  else
    printf '%s提示：未检测到宝塔，将自动安装独立 nginx。%s\n' "$C_YELLOW" "$C_RESET"
  fi

  if [[ -f "$STATE_FILE" ]]; then
    printf '\n%s注意：这台机器已经初始化过。%s\n' "$C_RED" "$C_RESET"
    printf '继续会重建本脚本的用户和线路；其他宝塔网站不受影响。\n'
    if ! menu_confirm "确定要重新初始化"; then
      return
    fi
    FORCE=1
  fi

  local role="gateway" name domain address mode cert key snippet=""
  local xhttp_enabled reality_enabled hy2_enabled tls_port route_port route_path
  local shared_tcp443=false auto_rebind_https=false
  local https_listen_port=8443 reality_listen_port
  local reality_port reality_path reality_target reality_sni
  local hy2_port hy2_obfs_password hy2_masquerade hy2_up hy2_down
  local hy2_shared_udp443=false hy2_share_choice
  local et_ip et_endpoint et_port et_name et_secret
  local username user_uuid user_password user_up user_down user_nodes
  local domain_audit_enabled
  local protocol_selection admin_selection admin_selection_normalized
  local value default_uuid default_password
  local -a admin_node_keys=() admin_node_labels=() selected_admin_nodes=()
  printf '\n'
  name="$(prompt_name_value '主服务器名称（仅用于菜单和订阅显示，例如 hk）' 'hk')"
  domain="$(prompt_hostname_value '主服务器入口域名（必须已解析到这台机器）' 'hk.example.com')"
  address="$domain"

  if (( is_baota )); then
    mode="snippet"
    cert="/www/server/panel/vhost/cert/${domain}/fullchain.pem"
    key="/www/server/panel/vhost/cert/${domain}/privkey.pem"
    snippet="/www/server/panel/vhost/nginx/extension/${domain}/etxr.conf"
  else
    mode="standalone"
    cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
    key="/etc/letsencrypt/live/${domain}/privkey.pem"
  fi

  if [[ -f "$cert" && -f "$key" ]]; then
    printf '%s✓ 已找到域名证书，不需要手动填写路径。%s\n' "$C_GREEN" "$C_RESET"
  else
    printf '%s没有在默认位置找到证书。%s\n' "$C_YELLOW" "$C_RESET"
    printf '文件不存在或不匹配时，后续检查会提示具体原因。\n'
    cert="$(prompt_value 'TLS 完整证书链路径（fullchain.pem）' "$cert")"
    key="$(prompt_value 'TLS 证书私钥路径（privkey.pem）' "$key")"
  fi

  protocol_selection="$(prompt_protocol_selection '1 3')"
  xhttp_enabled=n
  reality_enabled=n
  hy2_enabled=n
  [[ " $protocol_selection " != *" 1 "* ]] || xhttp_enabled=y
  [[ " $protocol_selection " != *" 2 "* ]] || reality_enabled=y
  [[ " $protocol_selection " != *" 3 "* ]] || hy2_enabled=y

  printf '\n%s【客户端连接主服务器：XHTTP + HTTPS】%s\n' "$C_BOLD" "$C_RESET"
  printf '公网端口供手机/电脑连接；Xray 本机端口只供 nginx 转发。\n'
  if [[ "$xhttp_enabled" == "y" ]]; then
    while true; do
      tls_port="$(prompt_port_value '网站和 XHTTP 的公网 HTTPS TCP 端口' '443')"
      if port_is_listening tcp "$tls_port"; then
        if (( is_baota )) && port_is_nginx_owned tcp "$tls_port"; then
          printf '%s✓ TCP %s 已由宝塔 nginx 监听，将安全共用。%s\n' \
            "$C_GREEN" "$tls_port" "$C_RESET"
          break
        fi
        warn "TCP 端口 $tls_port 已被其他程序占用"
        continue
      fi
      break
    done
    route_port="$(prompt_port_checked 'Xray XHTTP 本机接收 TCP 端口（无需开放防火墙）' '18001' tcp)"
    route_path="$(prompt_path_value 'XHTTP 连接 Path（纯随机，不包含节点名或协议名）' "$(random_path)")"
  else
    tls_port=443
    route_port=18001
    route_path="$(random_path)"
  fi

  printf '\n%s【客户端连接主服务器：Reality + XHTTP】%s\n' "$C_BOLD" "$C_RESET"
  if [[ "$reality_enabled" == "y" ]]; then
    if (( is_baota )) && [[ "$xhttp_enabled" == "y" ]]; then
      printf '选择共用后，网站、XHTTP 和 Reality 都使用公网 TCP 443，由 SNI 自动分流。\n'
      shared_tcp443="$(prompt_bool '让 Reality、XHTTP 和宝塔网站共用公网 TCP 443' y)"
    fi
    if [[ "$shared_tcp443" == "y" ]]; then
      tls_port=443
      printf '下面两个端口只在本机内部使用，客户端不连接，也无需开放防火墙。\n'
      https_listen_port="$(prompt_port_checked '宝塔网站迁移后的本机 HTTPS TCP 端口' '8443' tcp)"
      reality_port=443
      reality_listen_port="$(prompt_port_checked 'Xray Reality 本机接收 TCP 端口' '18443' tcp)"
      printf '%s脚本会先备份所有宝塔 HTTPS vhost，再把网站从公网 TCP 443 迁移到 127.0.0.1:%s；网站域名和客户端端口保持不变。%s\n' \
        "$C_YELLOW" "$https_listen_port" "$C_RESET"
      menu_confirm "确认让 ETXR 自动备份并调整宝塔 HTTPS 监听" || {
        FORCE=0
        return
      }
      auto_rebind_https=true
    else
      reality_port="$(prompt_port_checked 'Reality 公网 TCP 端口（需在防火墙放行）' '18443' tcp)"
      reality_listen_port="$reality_port"
    fi
    reality_path="$(prompt_path_value 'Reality 的 XHTTP 连接 Path（纯随机，不包含节点名或协议名）' "$(random_path)")"
    reality_target="$(prompt_target_value 'Reality 握手转发目标（域名:443）' 'aod.itunes.apple.com:443')"
    reality_sni="$(prompt_hostname_value 'Reality 客户端填写的伪装域名（SNI）' "${reality_target%%:*}")"
  else
    reality_port=18443
    reality_listen_port=18443
    reality_path="$(random_path)"
    reality_target="aod.itunes.apple.com:443"
    reality_sni="aod.itunes.apple.com"
  fi

  printf '\n%s【客户端连接主服务器：Hysteria2】%s\n' "$C_BOLD" "$C_RESET"
  printf 'Hysteria2 使用 UDP；网站 HTTPS 使用 TCP，两者可以同时使用数字 443。\n'
  if [[ "$hy2_enabled" == "y" ]]; then
    hy2_share_choice="$(prompt_bool '让 Hysteria2 使用公网 UDP 443' y)"
    if [[ "$hy2_share_choice" == "y" ]] && confirm_hy2_udp443_share; then
      hy2_port=443
      hy2_shared_udp443=true
    else
      if [[ "$hy2_share_choice" == "y" ]]; then
        printf '%s已取消 UDP 443 共用，请选择其他 Hysteria2 端口。%s\n' \
          "$C_YELLOW" "$C_RESET"
      fi
      hy2_port="$(prompt_port_checked 'Hysteria2 公网 UDP 端口（需在防火墙放行 UDP）' '8443' udp)"
      hy2_shared_udp443=false
    fi
    printf '下面是整条 Hysteria2 入站的带宽参数，不是单用户限速；0 表示不设置。\n'
    hy2_up="$(prompt_mbps 'Hysteria2 总上传带宽 Mbps' '0')"
    hy2_down="$(prompt_mbps 'Hysteria2 总下载带宽 Mbps' '0')"
    hy2_obfs_password="$(prompt_secret_default 'Hysteria2 混淆密码（客户端必须填写相同密码）' "$(random_password)")"
    hy2_masquerade="$(prompt_url_value 'Hysteria2 伪装网站 URL（需要包含 https://）' "https://${domain}")"
  else
    hy2_port=8443
    hy2_shared_udp443=false
    hy2_up=0
    hy2_down=0
    hy2_obfs_password=""
    hy2_masquerade="https://${domain}"
  fi

  printf '\n%s【管理员账号】%s\n' "$C_BOLD" "$C_RESET"
  printf '安装后会为这个用户生成 UUID 和订阅链接。\n'
  username="$(prompt_name_value '管理员用户名（仅用于 ETXR 用户管理）' 'admin')"
  default_uuid="$(random_uuid)"
  user_uuid="$(prompt_uuid_value '管理员 VLESS UUID（直接回车使用随机值）' "$default_uuid")"

  [[ "$xhttp_enabled" != "y" ]] || {
    admin_node_keys+=("${name}/xhttp/${name}")
    admin_node_labels+=("${name}-XHTTP")
  }
  [[ "$reality_enabled" != "y" ]] || {
    admin_node_keys+=("${name}/reality/reality")
    admin_node_labels+=("${name}-Reality-XHTTP")
  }
  [[ "$hy2_enabled" != "y" ]] || {
    admin_node_keys+=("${name}/hy2")
    admin_node_labels+=("${name}-Hysteria2")
  }
  printf '\n%s【选择管理员可以使用的节点】%s\n' "$C_BOLD" "$C_RESET"
  for value in "${!admin_node_keys[@]}"; do
    printf '  %d. %s\n' "$((value + 1))" "${admin_node_labels[$value]}"
  done
  while true; do
    read -r -p '请输入编号，可多选（例如 1 3）: ' admin_selection
    if admin_selection_normalized="$(normalize_index_selection \
      "$admin_selection" "${#admin_node_keys[@]}" false)"; then
      selected_admin_nodes=()
      for value in $admin_selection_normalized; do
        selected_admin_nodes+=("${admin_node_keys[$((value - 1))]}")
      done
      user_nodes="$(IFS=,; printf '%s' "${selected_admin_nodes[*]}")"
      break
    fi
    warn "请输入列表中的编号；多个编号用空格或逗号分隔"
  done
  user_password=""
  if [[ ",$user_nodes," == *",${name}/hy2,"* ]]; then
    default_password="$(random_password)"
    user_password="$(prompt_secret_default '管理员 Hysteria2 登录密码（直接回车使用随机值）' "$default_password")"
  fi
  user_up="$(prompt_mbps '该用户上传限速 Mbps（0 表示不限速）' '0')"
  user_down="$(prompt_mbps '该用户下载限速 Mbps（0 表示不限速）' '0')"

  printf '\n%s【访问域名统计】%s\n' "$C_BOLD" "$C_RESET"
  printf '启用后按用户记录访问域名、连接次数和时间，不记录完整 URL、请求内容或客户端 IP。\n'
  printf '从服务器会自动回报到主服务器；可随时停止或清空。\n'
  domain_audit_enabled="$(prompt_bool '启用按用户访问域名统计' n)"

  printf '\n%s【EasyTier 主从私网】%s\n' "$C_BOLD" "$C_RESET"
  printf '以后添加从服务器时，它们会主动连接下面的主服务器公网 TCP 端口。\n'
  et_ip="$(prompt_ipv4_value '主服务器在 EasyTier 私网中的 IP' '10.100.0.1')"
  et_endpoint="$(detect_public_ipv4)"
  et_endpoint="${et_endpoint:-$address}"
  et_endpoint="$(prompt_hostname_value '从服务器连接的主服务器公网 IP 或域名' "$et_endpoint")"
  et_port="$(prompt_port_checked 'EasyTier 公网 TCP 接入端口（需在主服务器防火墙放行）' '11010' tcp)"
  et_name="$(prompt_name_value 'EasyTier 私网名称（直接回车使用随机值）' "er-$(random_hex 8)")"
  et_secret="$(prompt_secret_default 'EasyTier 私网密钥（直接回车使用随机值）' "$(random_hex 24)")"

  if [[ "$shared_tcp443" == "y" ]]; then
    shared_tcp443=true
  else
    shared_tcp443=false
  fi
  printf '\n%s【配置确认】%s\n' "$C_BOLD" "$C_RESET"
  printf '  • HTTPS/XHTTP：%s' "$([[ "$xhttp_enabled" == "y" ]] && printf '开启' || printf '关闭')"
  [[ "$xhttp_enabled" != "y" ]] || printf '，公网 TCP %s，本机转发 TCP %s，Path %s' "$tls_port" "$route_port" "$route_path"
  printf '\n  • Reality：%s' "$([[ "$reality_enabled" == "y" ]] && printf '开启' || printf '关闭')"
  [[ "$reality_enabled" != "y" ]] || printf '，公网 TCP %s，本机接收 TCP %s，SNI %s' \
    "$reality_port" "$reality_listen_port" "$reality_sni"
  printf '\n  • Hysteria2：%s' "$([[ "$hy2_enabled" == "y" ]] && printf '开启' || printf '关闭')"
  [[ "$hy2_enabled" != "y" ]] || printf '，UDP %s%s，伪装 %s' \
    "$hy2_port" \
    "$([[ "$hy2_shared_udp443" == "true" ]] && printf '（与网站 TCP 443 同时使用；自动关闭 nginx H3）')" \
    "$hy2_masquerade"
  printf '\n  • EasyTier 主从私网：主服务器公网 TCP %s，私网 IP %s\n' "$et_port" "$et_ip"
  printf '  • 管理员：%s，上传 %s，下载 %s\n' \
    "$username" \
    "$([[ "$user_up" == "0" ]] && printf '不限速' || printf '%s Mbps' "$user_up")" \
    "$([[ "$user_down" == "0" ]] && printf '不限速' || printf '%s Mbps' "$user_down")"
  printf '  • 访问域名统计：%s\n\n' \
    "$([[ "$domain_audit_enabled" == "y" ]] && printf '开启' || printf '关闭')"
  if ! menu_confirm "确认开始安装"; then
    FORCE=0
    return
  fi

  printf '\n正在安装所需组件，通常需要 1～3 分钟……\n'
  menu_exec cmd_install --components "$install_components" || {
    FORCE=0
    menu_pause
    return
  }
  need_jq
  need_cmd openssl

  local -a args=(
    --name "$name" --role "$role" --domain "$domain" --address "$address"
    --nginx-mode "$mode" --cert "$cert" --key "$key" --tls-port "$tls_port"
    --nginx-shared-tcp443 "$shared_tcp443"
    --nginx-auto-rebind-https "$auto_rebind_https"
    --nginx-https-listen-port "$https_listen_port"
  )
  [[ "$mode" != "snippet" ]] || args+=(--snippet "$snippet")
  menu_exec cmd_init "${args[@]}" || {
    FORCE=0
    menu_pause
    return
  }
  FORCE=0
  if [[ "$domain_audit_enabled" == "y" ]]; then
    menu_exec cmd_domain enable || {
      menu_pause
      return
    }
  fi
  local route_name reality_keys reality_private reality_public reality_short
  menu_exec cmd_cluster_master_init --ip "$et_ip" --endpoint "$et_endpoint" \
    --port "$et_port" --network-name "$et_name" --network-secret "$et_secret" || {
    menu_pause
    return
  }

  menu_exec cmd_user_add --name "$username" --uuid "$user_uuid" \
    --password "$user_password" --nodes "$user_nodes" --up-mbps "$user_up" \
    --down-mbps "$user_down" || {
    menu_pause
    return
  }

  route_name="$name"
  if [[ "$xhttp_enabled" == "y" ]]; then
    menu_exec cmd_route_add --name "$route_name" --path "$route_path" \
      --port "$route_port" --target direct || {
        menu_pause
        return
      }
  fi

  if [[ "$reality_enabled" == "y" ]]; then
    reality_keys="$("$XRAY_BIN" x25519)"
    reality_private="$(awk -F': ' '/^PrivateKey:/ {print $2; exit}' <<<"$reality_keys")"
    reality_public="$(awk -F': ' '/^Password/ {print $2; exit}' <<<"$reality_keys")"
    if [[ -z "$reality_public" ]]; then
      reality_public="$(awk -F': ' '/^PublicKey:/ {print $2; exit}' <<<"$reality_keys")"
    fi
    [[ -n "$reality_private" && -n "$reality_public" ]] || {
      warn "无法解析 Xray Reality 密钥输出"
      menu_pause
      return
    }
    reality_short="$(random_hex 8)"
    menu_exec cmd_reality_add --name reality --port "$reality_port" \
      --listen-port "$reality_listen_port" \
      --listen-address "$([[ "$shared_tcp443" == "true" ]] && printf '127.0.0.1' || printf '0.0.0.0')" \
      --path "$reality_path" --target "$reality_target" \
      --server-names "$reality_sni" --private-key "$reality_private" \
      --public-key "$reality_public" --short-ids "$reality_short" || {
        menu_pause
        return
      }
  fi

  if [[ "$hy2_enabled" == "y" ]]; then
    local -a hy2_args=(
      --port "$hy2_port" --up-mbps "$hy2_up" --down-mbps "$hy2_down"
      --obfs salamander --obfs-password "$hy2_obfs_password"
      --masquerade "$hy2_masquerade"
    )
    if [[ "$hy2_shared_udp443" == "true" ]]; then
      hy2_args+=(--share-udp443)
    else
      hy2_args+=(--no-share-udp443)
    fi
    menu_exec cmd_hy2_enable "${hy2_args[@]}" || {
        menu_pause
        return
      }
  fi
  printf '\n%s✓ 基础配置已经生成。%s\n' "$C_GREEN" "$C_RESET"
  if [[ ! -f "$cert" || ! -f "$key" ]]; then
    printf '%s证书文件不存在，暂时没有启动。先在面板申请证书，再选择“一键检查与修复”。%s\n' \
      "$C_YELLOW" "$C_RESET"
  elif menu_apply_prompt; then
    printf '\n%s客户端订阅如下，请复制保存：%s\n' "$C_BOLD" "$C_RESET"
    menu_exec cmd_subscription "$username" || true
  fi
  menu_pause
}

menu_users() {
  local choice name route socks out uuid password default_name up_mbps down_mbps
  local nodes current_nodes current_password
  if [[ ! -f "$STATE_FILE" ]]; then
    warn "请先执行一键安装与初始化"
    menu_pause
    return
  fi
  if [[ "$(jq -r '.node.role' "$STATE_FILE")" == "exit" ]]; then
    warn "从服务器的用户和订阅由主服务器统一管理，请到主服务器操作"
    menu_pause
    return
  fi
  while true; do
    menu_header
    printf '%s【用户和订阅】%s\n' "$C_BOLD" "$C_RESET"
    printf '1. 新增一个用户          （选择该用户能使用哪些节点）\n'
    printf '2. 复制用户订阅          （手机/电脑直接导入）\n'
    printf '3. 查看所有用户\n'
    printf '4. 设置用户可用节点      （逐个开启或关闭节点）\n'
    printf '5. 暂停一个用户          （以后可以恢复）\n'
    printf '6. 恢复一个用户\n'
    printf '7. 永久删除用户\n'
    printf '8. 查看用户流量          （主从服务器自动汇总）\n'
    printf '9. 设置用户限速          （0 表示不限速）\n'
    printf '10. 清零用户流量\n'
    printf '11. 查看用户访问域名     （主从服务器自动汇总）\n'
    printf '12. 设置访问域名统计     （启用、停止、保留天数）\n'
    printf '13. 清空访问域名历史\n'
    printf '14. 导出单线路配置       （高级功能）\n'
    printf '0. 返回主菜单\n\n'
    read -r -p '请选择: ' choice
    case "$choice" in
      1)
        default_name="user$(( $(jq '.users | length' "$STATE_FILE") + 1 ))"
        name="$(prompt_name_value '用户名（仅用于 ETXR 用户管理和订阅名称）' "$default_name")"
        if jq -e --arg name "$name" '.users[]? | select(.name == $name)' \
          "$STATE_FILE" >/dev/null; then
          warn "用户已存在：$name"
          menu_pause
          continue
        fi
        uuid="$(prompt_uuid_value 'VLESS UUID（直接回车使用随机值）' "$(random_uuid)")"
        nodes="$(prompt_user_node_selection '[]' false)" || {
          menu_pause
          continue
        }
        password=""
        if [[ ",$nodes," == *"/hy2,"* ]]; then
          password="$(prompt_secret_default 'Hysteria2 登录密码（直接回车使用随机值）' "$(random_password)")"
        fi
        up_mbps="$(prompt_mbps '该用户上传限速 Mbps（0 表示不限速）' '0')"
        down_mbps="$(prompt_mbps '该用户下载限速 Mbps（0 表示不限速）' '0')"
        if menu_exec cmd_user_add --name "$name" --uuid "$uuid" \
          --password "$password" --nodes "$nodes" --up-mbps "$up_mbps" \
          --down-mbps "$down_mbps"; then
          if menu_apply_prompt; then
            printf '\n%s下面就是该用户的订阅：%s\n' "$C_BOLD" "$C_RESET"
            menu_exec cmd_subscription "$name" || true
          fi
        fi
        menu_pause
        ;;
      2)
        cmd_user_list || true
        name="$(prompt_value '要查看哪个用户的订阅')"
        menu_exec cmd_subscription "$name" || true
        menu_pause
        ;;
      3) menu_exec cmd_user_list || true; menu_pause ;;
      4)
        cmd_user_list || true
        name="$(prompt_value '要设置哪个用户')"
        current_nodes="$(jq -c --arg name "$name" \
          '.users[] | select(.name == $name) | (.enabled_nodes // ["*"])' \
          "$STATE_FILE" 2>/dev/null || true)"
        if [[ -z "$current_nodes" ]]; then
          warn "用户不存在：$name"
          menu_pause
          continue
        fi
        nodes="$(prompt_user_node_selection "$current_nodes" true)" || {
          menu_pause
          continue
        }
        password=""
        current_password="$(jq -r --arg name "$name" \
          '.users[] | select(.name == $name) | (.hy2_password // "")' \
          "$STATE_FILE")"
        if [[ ",$nodes," == *"/hy2,"* && -z "$current_password" ]]; then
          password="$(prompt_secret_default 'Hysteria2 登录密码（直接回车使用随机值）' "$(random_password)")"
        fi
        if menu_exec cmd_user_nodes "$name" --nodes "$nodes" \
          --password "$password"; then
          menu_apply_prompt || true
        fi
        menu_pause
        ;;
      5)
        cmd_user_list || true
        name="$(prompt_value '要暂停的用户名')"
        if menu_exec cmd_user disable "$name"; then menu_apply_prompt || true; fi
        menu_pause
        ;;
      6)
        cmd_user_list || true
        name="$(prompt_value '要恢复的用户名')"
        if menu_exec cmd_user enable "$name"; then menu_apply_prompt || true; fi
        menu_pause
        ;;
      7)
        cmd_user_list || true
        name="$(prompt_value '要删除的用户名')"
        if menu_confirm "永久删除 ${name}，确定继续"; then
          if menu_exec cmd_user_remove "$name"; then menu_apply_prompt || true; fi
        fi
        menu_pause
        ;;
      8)
        menu_exec cmd_user_usage || true
        menu_pause
        ;;
      9)
        cmd_user_list || true
        name="$(prompt_value '要设置哪个用户')"
        up_mbps="$(jq -r --arg name "$name" \
          '.users[] | select(.name == $name) | (.speed_limit.up_mbps // 0)' \
          "$STATE_FILE" 2>/dev/null || printf '0')"
        down_mbps="$(jq -r --arg name "$name" \
          '.users[] | select(.name == $name) | (.speed_limit.down_mbps // 0)' \
          "$STATE_FILE" 2>/dev/null || printf '0')"
        up_mbps="$(prompt_mbps '该用户上传限速 Mbps（0 表示不限速）' "${up_mbps:-0}")"
        down_mbps="$(prompt_mbps '该用户下载限速 Mbps（0 表示不限速）' "${down_mbps:-0}")"
        if menu_exec cmd_user_limit "$name" --up-mbps "$up_mbps" \
          --down-mbps "$down_mbps"; then
          menu_apply_prompt || true
        fi
        menu_pause
        ;;
      10)
        cmd_user_usage || true
        name="$(prompt_value '要清零哪个用户（全部用户填 all）')"
        if menu_confirm "清零 ${name} 在主从所有服务器上的累计流量，确定继续"; then
          if menu_exec cmd_user_reset_usage "$name"; then
            menu_apply_prompt || true
          fi
        fi
        menu_pause
        ;;
      11)
        cmd_user_list || true
        name="$(prompt_value '查看哪个用户（直接回车查看全部）')"
        menu_exec cmd_user_domains "$name" 100 || true
        menu_pause
        ;;
      12)
        menu_domain_audit
        ;;
      13)
        cmd_user_list || true
        name="$(prompt_value '清空哪个用户的记录（全部用户填 all）')"
        if menu_confirm "清空 ${name} 在主从所有服务器上的访问域名历史，确定继续"; then
          if menu_exec cmd_user_reset_domains "$name"; then
            menu_apply_prompt || true
          fi
        fi
        menu_pause
        ;;
      14)
        name="$(prompt_value '用户名称')"
        cmd_route_list || true
        route="$(prompt_value '线路名称')"
        socks="$(prompt_value '本地 SOCKS 端口' '10808')"
        out="$(prompt_value '输出文件' "/root/${name}-${route}-client.json")"
        menu_exec cmd_client "$name" --route "$route" --socks-port "$socks" --out "$out" || true
        menu_pause
        ;;
      0) return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

menu_domain_audit() {
  local choice retention maximum enabled
  while true; do
    menu_header
    enabled="$(jq -r '.domain_audit.enabled // false' "$STATE_FILE")"
    printf '%s【访问域名统计设置】%s\n' "$C_BOLD" "$C_RESET"
    printf '当前状态：%s\n' \
      "$([[ "$enabled" == "true" ]] && printf '正在记录' || printf '没有记录新连接')"
    printf '只保存用户、域名、连接次数和时间；不保存完整 URL、请求内容或客户端 IP。\n'
    printf '停止后不会新增记录，已有历史会保留，直到到期或手动清空。\n\n'
    printf '1. 启用统计\n'
    printf '2. 停止统计\n'
    printf '3. 修改保留天数和每用户域名上限\n'
    printf '4. 查看当前设置\n'
    printf '0. 返回用户菜单\n\n'
    read -r -p '请选择: ' choice
    case "$choice" in
      1)
        if menu_exec cmd_domain enable; then menu_apply_prompt || true; fi
        menu_pause
        ;;
      2)
        if menu_exec cmd_domain disable; then menu_apply_prompt || true; fi
        menu_pause
        ;;
      3)
        retention="$(jq -r '.domain_audit.retention_days // 30' "$STATE_FILE")"
        maximum="$(jq -r '.domain_audit.max_domains_per_user // 500' "$STATE_FILE")"
        while true; do
          retention="$(prompt_value '记录保留天数（1～365）' "$retention")"
          [[ "$retention" =~ ^[0-9]+$ ]] &&
            (( retention >= 1 && retention <= 365 )) && break
          warn "保留天数必须是 1 到 365"
        done
        while true; do
          maximum="$(prompt_value '每用户最多保留多少个域名（10～5000）' "$maximum")"
          [[ "$maximum" =~ ^[0-9]+$ ]] &&
            (( maximum >= 10 && maximum <= 5000 )) && break
          warn "每用户域名上限必须是 10 到 5000"
        done
        if menu_exec cmd_domain configure --retention-days "$retention" \
          --max-domains "$maximum"; then
          menu_apply_prompt || true
        fi
        menu_pause
        ;;
      4) menu_exec cmd_domain show || true; menu_pause ;;
      0) return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

next_route_port() {
  require_state
  jq -r '[.xray.routes[].port] | (max // 18000) + 1' "$STATE_FILE"
}

generate_vlessenc_pair() {
  if [[ ! -x "$XRAY_BIN" ]]; then
    warn "请先安装 Xray"
    return 1
  fi
  local output
  output="$("$XRAY_BIN" vlessenc)"
  VLESSENC_DECRYPTION="$(awk -F'"' '/"decryption"/ {v=$4} END {print v}' <<<"$output")"
  VLESSENC_ENCRYPTION="$(awk -F'"' '/"encryption"/ {v=$4} END {print v}' <<<"$output")"
  if [[ -z "$VLESSENC_DECRYPTION" || -z "$VLESSENC_ENCRYPTION" ]]; then
    warn "无法解析 xray vlessenc 输出"
    return 1
  fi
}

menu_routes() {
  local choice name path port target
  if [[ ! -f "$STATE_FILE" ]]; then
    warn "请先执行一键安装与初始化"
    menu_pause
    return
  fi
  while true; do
    menu_header
    printf '%s入口 Path 管理%s\n' "$C_BOLD" "$C_RESET"
    printf '1. 查看 Path\n'
    printf '2. 添加普通 TLS/XHTTP Path\n'
    printf '3. 添加 VLESS Encryption + Vision + XMUX Path\n'
    printf '4. 删除 Path\n'
    printf '0. 返回主菜单\n\n'
    read -r -p '请选择: ' choice
    case "$choice" in
      1) menu_exec cmd_route_list || true; menu_pause ;;
      2|3)
        printf '此处是高级功能：客户端用 Path 进入主服务器，nginx 再转到 Xray 本机端口。\n'
        name="$(prompt_value '线路名称（仅用于菜单和订阅显示）')"
        path="$(prompt_value '客户端连接主服务器时使用的 Path（默认纯随机）' "$(random_path)")"
        port="$(prompt_value 'Xray 本机接收 TCP 端口（无需开放防火墙）' "$(next_route_port)")"
        cmd_exit_list || true
        target="$(prompt_value '流量从哪里出去（direct=主服务器本机，或填写从服务器名称）' 'direct')"
        if [[ "$choice" == "3" ]]; then
          if generate_vlessenc_pair; then
            menu_exec cmd_route_add --name "$name" --path "$path" --port "$port" \
              --target "$target" --profile vlessenc-vision \
              --decryption "$VLESSENC_DECRYPTION" \
              --client-encryption "$VLESSENC_ENCRYPTION" || true
          fi
        else
          menu_exec cmd_route_add --name "$name" --path "$path" --port "$port" \
            --target "$target" || true
        fi
        menu_apply_prompt || true
        menu_pause
        ;;
      4)
        cmd_route_list || true
        name="$(prompt_value '要删除的线路名称')"
        if menu_confirm "确认删除 ${name}"; then
          menu_exec cmd_route_remove "$name" || true
          menu_apply_prompt || true
        fi
        menu_pause
        ;;
      0) return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

menu_exits() {
  local choice name address port server_name host path uuid public_key short_id
  local socks_username socks_password route_name route_port default_name
  if [[ ! -f "$STATE_FILE" ]]; then
    warn "请先执行一键安装与初始化"
    menu_pause
    return
  fi
  while true; do
    menu_header
    printf '%s出口分流管理%s\n' "$C_BOLD" "$C_RESET"
    printf '1. 查看已有出口\n'
    printf '2. 添加 SOCKS5 出口和 XHTTP Path\n'
    printf '3. 添加 TLS/XHTTP 出口\n'
    printf '4. 添加 Reality/XHTTP 出口\n'
    printf '5. 添加私网 VLESS Encryption 出口\n'
    printf '6. 删除出口\n'
    printf '0. 返回主菜单\n\n'
    read -r -p '请选择: ' choice
    case "$choice" in
      1) menu_exec cmd_exit_list || true; menu_pause ;;
      2)
        printf '客户端仍连接当前服务器的 XHTTP Path，流量再从指定 SOCKS5 代理出去。\n'
        printf '此功能只添加 SOCKS5 出口，不会开放 SOCKS5 入站端口。\n\n'
        default_name="socks$(( $(jq '.xray.exits | length' "$STATE_FILE") + 1 ))"
        name="$(prompt_name_value '出口机器名称（订阅中显示，例如 tw 或 us）' "$default_name")"
        address="$(prompt_value 'SOCKS5 服务器地址（本机代理填 127.0.0.1）' '127.0.0.1')"
        port="$(prompt_port_value 'SOCKS5 服务器端口' '10808')"
        socks_username="$(prompt_value 'SOCKS5 用户名（无需认证直接回车）')"
        socks_password=""
        if [[ -n "$socks_username" ]]; then
          socks_password="$(prompt_secret 'SOCKS5 密码')"
          while [[ -z "$socks_password" ]]; do
            warn "填写用户名后，密码不能为空"
            socks_password="$(prompt_secret 'SOCKS5 密码')"
          done
        fi
        route_name="$(prompt_name_value '这条 XHTTP 线路的管理名称' "${name}-socks")"
        path="$(prompt_value '客户端连接当前服务器时使用的 XHTTP Path（默认纯随机）' "$(random_path)")"
        route_port="$(prompt_port_checked 'Xray 本机接收 TCP 端口（无需开放防火墙）' "$(next_route_port)" tcp)"
        if menu_exec cmd_exit_add --name "$name" --address "$address" \
          --port "$port" --transport socks5 --username "$socks_username" \
          --password "$socks_password"; then
          if menu_exec cmd_route_add --name "$route_name" --path "$path" \
            --port "$route_port" --target "$name"; then
            menu_apply_prompt || true
          else
            cmd_exit_remove "$name" >/dev/null 2>&1 || true
            warn "XHTTP Path 创建失败，已删除刚才添加的 SOCKS5 出口"
          fi
        fi
        menu_pause
        ;;
      3)
        printf '当前入口服务器将通过 TLS/XHTTP 连接远程出口服务器。两端的域名、端口、Path 和 UUID 必须一致。\n'
        name="$(prompt_value '出口名称（仅用于菜单显示，例如 tw 或 us）')"
        address="$(prompt_value '当前入口服务器连接的出口服务器公网 IP 或域名')"
        server_name="$(prompt_value 'TLS 证书域名（SNI）' "$address")"
        host="$(prompt_value 'XHTTP Host（通常与 TLS SNI 相同）' "$server_name")"
        port="$(prompt_value '出口服务器公网 TCP 端口' '443')"
        path="$(prompt_value '出口服务器中继 Path（默认纯随机）' "$(random_path)")"
        uuid="$(prompt_value '主从中继 UUID（留空自动生成）')"
        uuid="${uuid:-$(random_uuid)}"
        menu_exec cmd_exit_add --name "$name" --address "$address" --port "$port" \
          --transport tls --server-name "$server_name" --host "$host" \
          --path "$path" --uuid "$uuid" || true
        printf '\n请在出口机创建：UUID=%s  Path=%s\n' "$uuid" "$path"
        menu_pause
        ;;
      4)
        printf '当前入口服务器将通过 Reality/XHTTP 连接远程出口服务器。以下参数必须与出口服务器一致。\n'
        name="$(prompt_value '出口名称（仅用于菜单显示）')"
        address="$(prompt_value '当前入口服务器连接的出口服务器公网 IP 或域名')"
        port="$(prompt_value '出口服务器 Reality 公网 TCP 端口' '443')"
        server_name="$(prompt_value 'Reality 客户端 SNI')"
        path="$(prompt_value 'Reality 的 XHTTP 连接 Path（默认纯随机）' "$(random_path)")"
        uuid="$(prompt_value '主从中继 UUID（留空自动生成）')"
        uuid="${uuid:-$(random_uuid)}"
        public_key="$(prompt_value 'Reality 公钥')"
        short_id="$(prompt_value 'Reality Short ID')"
        menu_exec cmd_exit_add --name "$name" --address "$address" --port "$port" \
          --transport reality --server-name "$server_name" --path "$path" \
          --uuid "$uuid" --public-key "$public_key" --short-id "$short_id" || true
        menu_pause
        ;;
      5)
        printf '当前入口服务器将通过 EasyTier/WireGuard 私网连接出口服务器，不需要开放公网中继端口。\n'
        name="$(prompt_value '出口名称（仅用于菜单显示）')"
        address="$(prompt_value '出口服务器的 EasyTier/WireGuard 私网 IP')"
        port="$(prompt_value '出口服务器私网中继 TCP 端口' '18000')"
        path="$(prompt_value '私网中继的 XHTTP Path（默认纯随机）' "$(random_path)")"
        uuid="$(prompt_value '主从中继 UUID（留空自动生成）')"
        uuid="${uuid:-$(random_uuid)}"
        if generate_vlessenc_pair; then
          menu_exec cmd_exit_add --name "$name" --address "$address" --port "$port" \
            --transport none --path "$path" --uuid "$uuid" \
            --encryption "$VLESSENC_ENCRYPTION" --flow xtls-rprx-vision || true
          printf '\n%s出口机需要保存以下服务端 decryption：%s\n%s\n' \
            "$C_YELLOW" "$C_RESET" "$VLESSENC_DECRYPTION"
          printf 'UUID=%s  Path=%s\n' "$uuid" "$path"
        fi
        menu_pause
        ;;
      6)
        cmd_exit_list || true
        name="$(prompt_value '要删除的出口名称')"
        if menu_confirm "确认删除 ${name}"; then
          menu_exec cmd_exit_remove "$name" || true
        fi
        menu_pause
        ;;
      0) return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

menu_add_reality() {
  if [[ ! -x "$XRAY_BIN" ]]; then
    warn "请先安装 Xray"
    return 1
  fi
  local output private_key public_key short_id name port listen_port path target sni
  output="$("$XRAY_BIN" x25519)"
  private_key="$(awk -F': ' '/^PrivateKey:/ {print $2}' <<<"$output")"
  public_key="$(awk -F': ' '/^Password/ {print $2}' <<<"$output")"
  short_id="$(random_hex 8)"
  name="$(prompt_value 'Reality 入站名称（仅用于菜单显示）' 'reality')"
  if [[ "$(jq -r '.nginx.shared_tcp443 // false' "$STATE_FILE")" == "true" ]]; then
    port=443
    listen_port="$(prompt_port_value 'Xray Reality 本机接收 TCP 端口（无需开放防火墙）' '18443')"
  else
    port="$(prompt_value 'Reality 公网 TCP 端口（需在防火墙放行）' '8444')"
    listen_port="$port"
  fi
  path="$(prompt_value 'Reality 的 XHTTP 连接 Path（默认纯随机）' "$(random_path)")"
  target="$(prompt_value 'Reality 握手转发目标（域名:443）' 'aod.itunes.apple.com:443')"
  sni="$(prompt_value 'Reality 客户端填写的伪装域名（SNI）' "${target%%:*}")"
  menu_exec cmd_reality_add --name "$name" --port "$port" \
    --listen-port "$listen_port" --path "$path" \
    --target "$target" --server-names "$sni" \
    --private-key "$private_key" --public-key "$public_key" \
    --short-ids "$short_id" || return
  printf '\nReality 公钥：%s\nReality Short ID：%s\n' "$public_key" "$short_id"
}

menu_protocols() {
  local choice port up down masquerade name shared_udp443 share_choice obfs_password
  if [[ ! -f "$STATE_FILE" ]]; then
    warn "请先执行一键安装与初始化"
    menu_pause
    return
  fi
  while true; do
    menu_header
    printf '%s独立协议管理%s\n' "$C_BOLD" "$C_RESET"
    printf '1. 查看 Reality 入站\n'
    printf '2. 自动添加 Reality + XHTTP 入站\n'
    printf '3. 删除 Reality 入站\n'
    printf '4. 启用/修改 Hysteria2\n'
    printf '5. 禁用 Hysteria2\n'
    printf '6. 查看 Hysteria2 配置\n'
    printf '0. 返回主菜单\n\n'
    read -r -p '请选择: ' choice
    case "$choice" in
      1) menu_exec cmd_reality_list || true; menu_pause ;;
      2) menu_add_reality || true; menu_apply_prompt || true; menu_pause ;;
      3)
        cmd_reality_list || true
        name="$(prompt_value '要删除的 Reality 名称')"
        menu_exec cmd_reality_remove "$name" || true
        menu_apply_prompt || true
        menu_pause
        ;;
      4)
        shared_udp443=false
        printf '网站使用 TCP，Hysteria2 使用 UDP；两者可以同时使用数字 443。\n'
        share_choice="$(prompt_bool '让 Hysteria2 使用公网 UDP 443' y)"
        if [[ "$share_choice" == "y" ]] && confirm_hy2_udp443_share; then
          port=443
          shared_udp443=true
        else
          if [[ "$share_choice" == "y" ]]; then
            printf '%s已取消 UDP 443 共用，请选择其他 Hysteria2 端口。%s\n' \
              "$C_YELLOW" "$C_RESET"
          fi
          port="$(prompt_port_checked 'Hysteria2 公网 UDP 端口（需在防火墙放行 UDP）' '8443' udp)"
        fi
        printf '下面是整条 Hysteria2 入站的带宽参数，不是单用户限速；0 表示不设置。\n'
        up="$(prompt_mbps 'Hysteria2 总上传带宽 Mbps' '0')"
        down="$(prompt_mbps 'Hysteria2 总下载带宽 Mbps' '0')"
        obfs_password="$(prompt_secret_default 'Hysteria2 混淆密码（客户端必须填写相同密码）' "$(random_password)")"
        masquerade="$(prompt_url_value 'Hysteria2 伪装网站 URL（需要包含 https://）' 'https://www.cloudflare.com')"
        local -a hy2_args=(
          --port "$port" --up-mbps "$up" --down-mbps "$down"
          --obfs salamander --obfs-password "$obfs_password"
          --masquerade "$masquerade"
        )
        if [[ "$shared_udp443" == "true" ]]; then
          hy2_args+=(--share-udp443)
        else
          hy2_args+=(--no-share-udp443)
        fi
        menu_exec cmd_hy2_enable "${hy2_args[@]}" || true
        menu_apply_prompt || true
        menu_pause
        ;;
      5)
        menu_exec cmd_hy2 disable || true
        menu_apply_prompt || true
        menu_pause
        ;;
      6) menu_exec cmd_hy2 show || true; menu_pause ;;
      0) return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

menu_config_actions() {
  local choice
  if [[ ! -f "$STATE_FILE" ]]; then
    warn "请先执行一键安装与初始化"
    menu_pause
    return
  fi
  while true; do
    menu_header
    printf '%s配置生成与应用%s\n' "$C_BOLD" "$C_RESET"
    printf '1. 生成配置\n'
    printf '2. 检查配置\n'
    printf '3. 备份并应用配置\n'
    printf '4. 备份当前配置\n'
    printf '0. 返回主菜单\n\n'
    read -r -p '请选择: ' choice
    case "$choice" in
      1) menu_exec cmd_render || true; menu_pause ;;
      2) menu_exec cmd_validate || true; menu_pause ;;
      3) menu_exec cmd_apply || true; menu_pause ;;
      4) menu_exec cmd_backup || true; menu_pause ;;
      0) return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

menu_xray() {
  local choice
  while true; do
    menu_header
    printf '%sXray 管理%s\n' "$C_BOLD" "$C_RESET"
    printf '1. 查看状态与资源占用\n'
    printf '2. 启动 Xray\n'
    printf '3. 停止 Xray\n'
    printf '4. 重启 Xray\n'
    printf '5. 查看最近日志\n'
    printf '6. 查看实时日志\n'
    printf '7. 实时连接监控\n'
    printf '8. 检查 Xray 更新\n'
    printf '9. 更新 Xray（自动备份与回滚）\n'
    printf '0. 返回主菜单\n\n'
    read -r -p '请选择: ' choice
    case "$choice" in
      1) menu_exec cmd_xray_status || true; menu_pause ;;
      2) menu_exec cmd_xray_service_action start || true; menu_pause ;;
      3) menu_exec cmd_xray_service_action stop || true; menu_pause ;;
      4) menu_exec cmd_xray_service_action restart || true; menu_pause ;;
      5) menu_exec cmd_xray_logs 100 || true; menu_pause ;;
      6) menu_exec cmd_xray_follow || true ;;
      7) menu_exec cmd_xray_monitor || true ;;
      8) menu_exec cmd_xray_check_update || true; menu_pause ;;
      9) menu_exec cmd_xray_update || true; menu_pause ;;
      0) return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

menu_worker_join() {
  clear_screen
  printf '%s%s【从服务器加入向导】%s\n\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
  if ! base_packages_ready; then
    printf '首次使用需要安装 jq、openssl 等 Pair ID 验签工具。\n'
    printf '这里只安装 Debian 基础工具，不会提前安装或修改 Xray、nginx。\n\n'
    if ! menu_exec ensure_pair_join_tools; then
      menu_pause
      return
    fi
    printf '\n%s✓ Pair ID 验签工具已准备完成。%s\n\n' "$C_GREEN" "$C_RESET"
  fi
  printf '把主服务器生成的配对 ID 和签名指纹粘贴到下面，然后回车。\n'
  printf '配对验证通过后，再在这台从服务器选择 XHTTP、Reality、Hysteria2 和 443 共用。\n'
  printf '协议密钥在本机生成；有宝塔就复用宝塔 nginx，没有才安装标准 nginx。\n'
  printf '%s粘贴时屏幕不会显示字符，这是正常的。%s\n\n' "$C_YELLOW" "$C_RESET"
  local pairing_id fingerprint
  pairing_id="$(prompt_secret '请粘贴配对 ID')"
  [[ -n "$pairing_id" ]] || {
    warn "配对 ID 为空"
    menu_pause
    return
  }
  fingerprint="$(prompt_value '请输入主服务器显示的 32 位签名指纹')"
  [[ "$fingerprint" =~ ^[0-9a-fA-F]{32}$ ]] || {
    warn "签名指纹必须是 32 位十六进制字符"
    menu_pause
    return
  }
  if [[ -f "$STATE_FILE" ]]; then
    printf '%s这台机器已有本脚本配置，继续会替换旧的 ETXR 配置。%s\n' \
      "$C_YELLOW" "$C_RESET"
    menu_confirm "确定继续" || {
      menu_pause
      return
    }
  fi
  printf '\n配对已准备完成，接下来配置这台从服务器自己的客户端入口。\n'
  if menu_exec cmd_pair_join --configure-direct \
    --fingerprint "$fingerprint" "$pairing_id"; then
    printf '\n%s✓ 从服务器已加入成功。现在可以回到主服务器复制订阅测试。%s\n' \
      "$C_GREEN" "$C_RESET"
  fi
  menu_pause
}

menu_pair_create() {
  if [[ ! -f "$STATE_FILE" ]]; then
    warn "请先完成主服务器一键初始化"
    menu_pause
    return
  fi
  if [[ "$(jq -r '.node.role' "$STATE_FILE")" == "exit" ]]; then
    warn "这台是从服务器。请回到主服务器执行【添加从服务器】。"
    menu_pause
    return
  fi
  local name public_host="" backup_port=29000 backup_listen_port=29000
  local relay_private_port=19000 mode_choice
  local relay_uuid pair_expires_minutes
  clear_screen
  printf '%s%s【添加从服务器：第一步，在主服务器生成 Pair ID】%s\n\n' \
    "$C_BOLD" "$C_CYAN" "$C_RESET"
  printf '本向导只设置“主服务器怎样把流量送到从服务器”。\n'
  printf 'XHTTP、Reality、Hysteria2、域名、证书和 443 共用稍后在从服务器设置。\n'
  printf '公网可达时优先走公网；公网连接失败时自动改走 EasyTier 私网。\n\n'
  name="$(prompt_name_value '从服务器名称（仅用于菜单显示，例如 tw1）' 'tw1')"
  pair_expires_minutes="$(prompt_value 'Pair ID 可使用多少分钟（过期后需重新生成）' '30')"
  if [[ ! "$pair_expires_minutes" =~ ^[0-9]+$ ]] ||
     (( 10#$pair_expires_minutes < 1 || 10#$pair_expires_minutes > 525600 )); then
    warn "有效期必须是 1 到 525600 分钟之间的整数"
    menu_pause
    return
  fi
  printf '\n%s从服务器的公网端口属于哪种情况？%s\n' "$C_BOLD" "$C_RESET"
  printf '1. 没有可用公网 TCP 端口\n'
  printf '   主服务器只能通过 EasyTier 私网连接，最省事。\n'
  printf '2. 有独立公网 IP，可以直接开放 TCP 端口\n'
  printf '   主服务器优先直连从服务器公网端口，EasyTier 自动备用。\n'
  printf '3. NAT 机器，服务商提供了公网 TCP 端口映射\n'
  printf '   主服务器连接外部映射端口，再转到从服务器本机监听端口。\n'
  read -r -p '请选择 [1]: ' mode_choice
  mode_choice="${mode_choice:-1}"
  if [[ "$mode_choice" == "2" ]]; then
    public_host="$(prompt_hostname_value '从服务器公网 IP 或域名（主服务器连接这个地址）' "${name}.example.com")"
  elif [[ "$mode_choice" == "3" ]]; then
    public_host="$(prompt_hostname_value '服务商提供的公网映射地址（IP 或域名）' "${name}.example.com")"
  elif [[ "$mode_choice" != "1" ]]; then
    warn "选项无效"
    menu_pause
    return
  fi

  printf '\n%s【EasyTier 备用线路】%s\n' "$C_BOLD" "$C_RESET"
  printf '下面的端口监听在从服务器的 EasyTier 私网 IP 上，无需在公网防火墙放行。\n'
  relay_private_port="$(prompt_port_value '从服务器 EasyTier 私网中继 TCP 端口' '19000')"
  relay_uuid="$(prompt_uuid_value '主从中继身份 UUID（直接回车使用随机值）' "$(random_uuid)")"
  if [[ "$mode_choice" == "2" ]]; then
    printf '\n%s【公网优先线路：独立公网 IP】%s\n' "$C_BOLD" "$C_RESET"
    printf '该端口监听在从服务器公网 IP 上，主服务器会优先连接它。\n'
    backup_port="$(prompt_port_value '从服务器公网中继 TCP 端口（需在防火墙放行）' '29000')"
    backup_listen_port="$backup_port"
  elif [[ "$mode_choice" == "3" ]]; then
    printf '\n%s【公网优先线路：NAT 端口映射】%s\n' "$C_BOLD" "$C_RESET"
    printf '外部端口由主服务器连接；内部端口由从服务器 Xray 监听。\n'
    backup_port="$(prompt_port_value '服务商提供的公网映射 TCP 端口（外部端口）' '29000')"
    backup_listen_port="$(prompt_port_value '从服务器本机中继 TCP 端口（映射目标端口）' '29000')"
  fi
  if [[ "$mode_choice" != "1" && "$backup_listen_port" == "$relay_private_port" ]]; then
    warn "公网中继的从服务器监听端口不能与 EasyTier 私网中继端口相同"
    warn "请重新添加，并为两条线路使用不同端口，例如私网 19000、公网 29000"
    menu_pause
    return
  fi

  printf '\n%s【将要使用的连接方式】%s\n' "$C_BOLD" "$C_RESET"
  case "$mode_choice" in
    1)
      printf '主服务器 -> EasyTier 私网 -> 从服务器 TCP %s\n' "$relay_private_port"
      printf '公网防火墙：无需为主从中继开放端口。\n'
      ;;
    2)
      printf '优先：主服务器 -> %s:%s -> 从服务器 Xray\n' \
        "$public_host" "$backup_port"
      printf '备用：主服务器 -> EasyTier 私网 -> 从服务器 TCP %s\n' \
        "$relay_private_port"
      printf '防火墙：从服务器放行 TCP %s，建议只允许主服务器公网 IP。\n' \
        "$backup_port"
      ;;
    3)
      printf '优先：主服务器 -> %s:%s -> 端口映射 -> 从服务器 TCP %s\n' \
        "$public_host" "$backup_port" "$backup_listen_port"
      printf '备用：主服务器 -> EasyTier 私网 -> 从服务器 TCP %s\n' \
        "$relay_private_port"
      printf '服务商面板需添加：公网 TCP %s -> 从服务器 TCP %s。\n' \
        "$backup_port" "$backup_listen_port"
      ;;
  esac
  printf '%s从服务器粘贴 Pair ID 后，脚本会检查本机端口占用并生成 Reality 密钥。%s\n' \
    "$C_YELLOW" "$C_RESET"

  local -a args=(
    --name "$name"
    --private-relay-port "$relay_private_port"
    --relay-uuid "$relay_uuid"
    --public-relay-port "$backup_port"
    --public-listen-port "$backup_listen_port"
    --no-xhttp
    --no-reality
    --no-hy2
    --expires-minutes "$pair_expires_minutes"
  )
  [[ -z "$public_host" ]] || args+=(--public-host "$public_host")
  if menu_exec cmd_pair_create "${args[@]}"; then
    printf '\n%s下一步只有一件事：%s\n' "$C_BOLD" "$C_RESET"
    printf '%s把上面的 ER2 开头配对 ID 和签名指纹完整复制到从服务器，并选择主菜单第 2 项。%s\n' \
      "$C_GREEN" "$C_RESET"
    printf '协议、域名、证书、Path 和 443 共用全部在从服务器上选择。\n'
    menu_apply_prompt || true
  fi
  menu_pause
}

menu_pair_manage() {
  if [[ ! -f "$STATE_FILE" ]]; then
    warn "尚未初始化"
    menu_pause
    return
  fi
  local choice name expires pair_expires_minutes
  while true; do
    menu_header
    printf '%s主从节点管理%s\n' "$C_BOLD" "$C_RESET"
    printf '1. 查看所有从服务器\n'
    printf '2. 添加从服务器并生成配对 ID\n'
    printf '3. 再次显示仍在有效期内的 Pair ID\n'
    printf '4. Pair ID 已过期：为原从服务器续发新 ID\n'
    printf '5. 删除从服务器\n'
    printf '6. 查看 EasyTier 节点\n'
    printf '7. 查看配置下发状态\n'
    printf '0. 返回主菜单\n\n'
    read -r -p '请选择: ' choice
    case "$choice" in
      1) menu_exec cmd_pair_list || true; menu_pause ;;
      2) menu_pair_create ;;
      3)
        name="$(prompt_value '从服务器名称（添加时填写的短名字）')"
        if [[ -f "$RUNTIME_DIR/pairs/${name}.id" ]]; then
          expires="$(jq -r --arg name "$name" \
            '.paired_nodes[]? | select(.name == $name) | .expires_at // 0' \
            "$STATE_FILE")"
          if [[ "$expires" =~ ^[0-9]+$ ]] &&
             (( 10#$expires <= $(date +%s) )); then
            warn "这个 Pair ID 已过期，从服务器不能再使用它加入"
            printf '请选择第 4 项，为同一个从服务器续发新的 Pair ID。\n'
          else
            cat "$RUNTIME_DIR/pairs/${name}.id"
            printf '\n'
          fi
        else
          warn "未找到该配对 ID"
        fi
        menu_pause
        ;;
      4)
        name="$(prompt_value '要续发 Pair ID 的从服务器名称')"
        pair_expires_minutes="$(prompt_value '新的 Pair ID 可使用多少分钟' '30')"
        if [[ ! "$pair_expires_minutes" =~ ^[0-9]+$ ]] ||
           (( 10#$pair_expires_minutes < 1 ||
              10#$pair_expires_minutes > 525600 )); then
          warn "有效期必须是 1 到 525600 分钟之间的整数"
        else
          menu_exec cmd_pair_renew "$name" \
            --expires-minutes "$pair_expires_minutes" || true
        fi
        menu_pause
        ;;
      5)
        name="$(prompt_value '要删除的从服务器名称（添加时填写的短名字）')"
        if menu_confirm "确认删除 ${name} 的线路与出口"; then
          menu_exec cmd_pair_remove "$name" || true
          menu_apply_prompt || true
        fi
        menu_pause
        ;;
      6)
        if [[ -x "$EASYTIER_CLI_BIN" ]]; then
          "$EASYTIER_CLI_BIN" peer || true
          "$EASYTIER_CLI_BIN" route || true
        else
          warn "EasyTier 尚未安装"
        fi
        menu_pause
        ;;
      7) menu_exec cmd_control_status || true; menu_pause ;;
      0) return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

health_result() {
  local ok="$1" label="$2" detail="${3:-}"
  if [[ "$ok" == "1" ]]; then
    printf '  %s✓%s %-22s %s\n' "$C_GREEN" "$C_RESET" "$label" "$detail"
  else
    printf '  %s✗%s %-22s %s\n' "$C_RED" "$C_RESET" "$label" "$detail"
  fi
}

menu_health_check() {
  clear_screen
  printf '%s%s【一键检查】%s\n\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
  if [[ ! -f "$STATE_FILE" ]]; then
    health_result 0 "基础配置" "尚未安装"
    printf '\n请返回主菜单，选择 1（主服务器）或 2（从服务器）开始安装。\n'
    menu_pause
    return
  fi

  local failures=0 xray_config sing_config cert key mode nb role limited_count
  local health_hy2_port health_hy2_shared listener_ok
  local health_quic_manifest health_quic_count health_quic_file
  xray_config="$(jq -r '.xray.config_path' "$STATE_FILE")"
  sing_config="$(jq -r '.hysteria2.config_path' "$STATE_FILE")"
  cert="$(jq -r '.nginx.certificate' "$STATE_FILE")"
  key="$(jq -r '.nginx.certificate_key' "$STATE_FILE")"
  mode="$(jq -r '.nginx.mode' "$STATE_FILE")"
  role="$(jq -r '.node.role' "$STATE_FILE")"
  limited_count="$(jq '[
    .users[] |
    select(
      .enabled == true and
      (((.speed_limit.up_mbps // 0) > 0) or
       ((.speed_limit.down_mbps // 0) > 0))
    )
  ] | length' "$STATE_FILE")"

  if jq -e '.schema_version == 1' "$STATE_FILE" >/dev/null 2>&1; then
    health_result 1 "基础配置" "正常"
  else
    health_result 0 "基础配置" "state.json 损坏"
    ((failures+=1))
  fi

  if systemctl is-active --quiet etxr-easytier.service; then
    health_result 1 "主从组网" "正在运行"
  else
    health_result 0 "主从组网" "服务未运行"
    ((failures+=1))
  fi

  if systemctl is-active --quiet etxr-xray.service; then
    health_result 1 "Xray 核心" "正在运行"
  else
    health_result 0 "Xray 核心" "服务未运行"
    ((failures+=1))
  fi

  if systemctl is-active --quiet etxr-meter.service; then
    health_result 1 "用户流量统计" "正在运行"
  else
    health_result 0 "用户流量统计" "服务未运行"
    ((failures+=1))
  fi

  if [[ "$(jq -r '.domain_audit.enabled // false' "$STATE_FILE")" == "true" ]]; then
    if systemctl is-active --quiet etxr-domain-audit.service &&
       [[ -S "$DOMAIN_SOCKET" ]]; then
      health_result 1 "用户访问域名统计" "正在运行"
    else
      health_result 0 "用户访问域名统计" "服务未运行或本机 Socket 不存在"
      ((failures+=1))
    fi
  else
    health_result 1 "用户访问域名统计" "未启用（不是故障）"
  fi

  if (( limited_count > 0 )); then
    if systemctl is-active --quiet etxr-limiter.service; then
      health_result 1 "单用户限速" "${limited_count} 个用户已启用"
    else
      health_result 0 "单用户限速" "有限速用户，但服务未运行"
      ((failures+=1))
    fi
  else
    health_result 1 "单用户限速" "未设置（不是故障）"
  fi

  if [[ "$role" == "exit" ]]; then
    if [[ "$(jq -r '.control.agent.enabled // false' "$STATE_FILE")" == "true" ]] &&
       systemctl is-active --quiet etxr-agent.service; then
      health_result 1 "配置接收 Agent" "WSS 已启动"
    else
      health_result 0 "配置接收 Agent" "服务未运行或未配置"
      ((failures+=1))
    fi
  else
    if [[ "$(jq -r '.control.enabled // false' "$STATE_FILE")" == "true" ]] &&
       systemctl is-active --quiet etxr-control.service; then
      health_result 1 "配置下发服务" "本机 127.0.0.1:$(jq -r '.control.port' "$STATE_FILE")"
    else
      health_result 0 "配置下发服务" "服务未运行或未配置"
      ((failures+=1))
    fi
  fi

  if [[ -s "$xray_config" ]] &&
     "$XRAY_BIN" run -test -config "$xray_config" >/dev/null 2>&1; then
    health_result 1 "Xray 配置" "检查通过"
  else
    health_result 0 "Xray 配置" "配置为空或检查失败"
    ((failures+=1))
  fi

  if [[ "$(jq -r '.hysteria2.enabled' "$STATE_FILE")" == "true" ]]; then
    health_hy2_port="$(jq -r '.hysteria2.port' "$STATE_FILE")"
    health_hy2_shared="$(jq -r '.hysteria2.shared_udp443 // false' "$STATE_FILE")"
    listener_ok=1
    if command -v ss >/dev/null 2>&1; then
      if ! port_is_sing_box_owned udp "$health_hy2_port"; then
        listener_ok=0
      elif [[ "$health_hy2_shared" == "true" ]] &&
           port_is_nginx_owned udp "$health_hy2_port"; then
        listener_ok=0
      fi
    fi
    if systemctl is-active --quiet etxr-sing-box.service &&
       [[ -s "$sing_config" ]] &&
       "$SING_BOX_BIN" check -c "$sing_config" >/dev/null 2>&1 &&
       (( listener_ok )); then
      health_result 1 "Hysteria2" "正在运行，UDP ${health_hy2_port}"
    else
      health_result 0 "Hysteria2" "服务、配置或 UDP ${health_hy2_port} 监听异常"
      ((failures+=1))
    fi
  else
    health_result 1 "Hysteria2" "未启用（不是故障）"
  fi

  if [[ "$mode" == "disabled" ]]; then
    health_result 1 "nginx/证书" "从服务器无需 nginx"
  else
    if [[ -f "$cert" && -f "$key" ]]; then
      health_result 1 "TLS 证书" "文件存在"
    else
      health_result 0 "TLS 证书" "证书或私钥不存在"
      ((failures+=1))
    fi
    if nb="$(nginx_bin 2>/dev/null)" && "$nb" -t >/dev/null 2>&1; then
      health_result 1 "nginx 配置" "检查通过"
    else
      health_result 0 "nginx 配置" "检查失败"
      ((failures+=1))
    fi

    if [[ "$health_hy2_shared" == "true" ]]; then
      health_quic_manifest="$(mktemp)"
      nginx_quic_active_manifest "$health_quic_manifest"
      if [[ -s "$health_quic_manifest" ]]; then
        health_quic_count=0
        health_result 0 "nginx H3/QUIC" "发现仍启用的配置；一键修复会自动关闭"
        while IFS= read -r -d '' health_quic_file; do
          health_quic_count=$((health_quic_count + 1))
          printf '    - %s\n' "$health_quic_file"
        done <"$health_quic_manifest"
        printf '    共发现 %s 个配置文件。\n' "$health_quic_count"
        ((failures+=1))
      else
        health_result 1 "nginx H3/QUIC" "已关闭（HY2 共用 UDP 443）"
      fi
      rm -f "$health_quic_manifest"
    fi
  fi

  printf '\n'
  if (( failures == 0 )); then
    printf '%s✓ 所有关键项目都正常，可以直接使用。%s\n' "$C_GREEN" "$C_RESET"
  else
    printf '%s发现 %s 个问题。%s\n' "$C_RED" "$failures" "$C_RESET"
    if menu_confirm "是否立即尝试重新生成配置并启动服务"; then
      menu_apply_prompt || true
    else
      printf '可进入“高级设置 → 查看日志”了解详细原因。\n'
    fi
  fi

  if [[ -x "$EASYTIER_CLI_BIN" ]]; then
    printf '\n当前主从连接：\n'
    "$EASYTIER_CLI_BIN" peer 2>/dev/null || true
  fi
  menu_pause
}

menu_quick_subscription() {
  if [[ ! -f "$STATE_FILE" ]]; then
    warn "这台机器还没有安装"
    menu_pause
    return
  fi
  if [[ "$(jq -r '.node.role' "$STATE_FILE")" == "exit" ]]; then
    warn "从服务器不提供订阅，请到主服务器复制集中订阅"
    menu_pause
    return
  fi
  local count username
  count="$(jq -r '[.users[] | select(.enabled == true)] | length' "$STATE_FILE")"
  if (( count == 0 )); then
    warn "还没有可用用户，请先进入【用户和订阅】新增用户"
  elif (( count == 1 )); then
    username="$(jq -r '.users[] | select(.enabled == true) | .name' "$STATE_FILE")"
    printf '%s当前唯一用户：%s%s\n\n' "$C_CYAN" "$username" "$C_RESET"
    menu_exec cmd_subscription "$username" || true
  else
    cmd_user_list || true
    username="$(prompt_value '要复制哪个用户的订阅')"
    menu_exec cmd_subscription "$username" || true
  fi
  menu_pause
}

menu_self_update() {
  clear_screen
  printf '%s%s【更新 ETXR 管理脚本】%s\n\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
  printf '此功能更新 ETXR 脚本、Go 数据面和控制组件，不会删除用户或线路配置。\n'
  printf '更新前自动备份；校验、安装或服务重启失败时自动恢复旧版本。\n\n'
  if menu_exec cmd_self_check_update; then
    printf '\n'
    if menu_confirm "现在更新到 GitHub 最新正式版"; then
      YES=1
      if menu_exec cmd_self_update; then
        YES=0
        printf '\n%s即将重新载入新版菜单。%s\n' "$C_GREEN" "$C_RESET"
        sleep 1
        exec "$SELF_BIN" menu
      fi
      YES=0
    fi
  fi
  menu_pause
}

menu_migration() {
  local choice package default_package
  while true; do
    menu_header
    printf '%s【配置迁移】%s\n\n' "$C_BOLD" "$C_RESET"
    printf '迁移包会使用密码加密，可保存用户、线路、密钥和统计数据。\n'
    printf '不会打包证书、宝塔网站配置或自动生成的运行配置。\n'
    printf '导入新服务器时会重新询问域名和证书路径。\n\n'
    printf '1. 导出这台服务器的配置\n'
    printf '2. 在这台服务器导入迁移包\n'
    printf '0. 返回主菜单\n\n'
    read -r -p '请输入数字: ' choice
    case "$choice" in
      1)
        if [[ ! -f "$STATE_FILE" ]]; then
          warn "这台服务器还没有 ETXR 配置，无法导出"
          menu_pause
          continue
        fi
        default_package="/root/etxr-migration-$(date +%Y%m%d-%H%M%S).etxrm"
        package="$(prompt_value '迁移包保存路径' "$default_package")"
        printf '\n迁移密码至少 12 个字符，丢失后无法恢复迁移包。\n'
        menu_exec cmd_migration_export --out "$package" || true
        menu_pause
        ;;
      2)
        package="$(prompt_value '迁移包的绝对路径')"
        printf '\n%s导入前请确认：%s\n' "$C_YELLOW" "$C_RESET"
        printf '  • 新域名已经解析到这台服务器\n'
        printf '  • 这台新服务器还没有初始化 ETXR\n'
        printf '  • 需要 HTTPS/Hysteria2 时，新证书已经部署\n'
        printf '  • 导入失败会恢复这台服务器原有的 ETXR 状态\n\n'
        if menu_confirm "确认开始检查并导入迁移包"; then
          menu_exec cmd_migration_import "$package" || true
        fi
        menu_pause
        ;;
      0) return ;;
      *) warn "请输入菜单中已有的数字"; sleep 1 ;;
    esac
  done
}

menu_advanced() {
  local choice
  while true; do
    menu_header
    printf '%s【高级设置】%s\n' "$C_BOLD" "$C_RESET"
    printf '%s一般使用不需要进入这里。%s\n\n' "$C_YELLOW" "$C_RESET"
    printf '1. 管理主服务器的 XHTTP Path\n'
    printf '2. 管理 Reality / Hysteria2\n'
    printf '3. 生成、检查、备份和应用配置\n'
    printf '4. Xray 启停、日志、监控和更新\n'
    printf '5. 查看完整节点状态\n'
    printf '6. 管理从服务器（查看 ID / 删除 / 连接详情）\n'
    printf '7. 管理出口分流          （SOCKS5 / 远程出口）\n'
    printf '8. 检查并更新 ETXR 管理脚本\n'
    printf '0. 返回新手首页\n\n'
    read -r -p '请输入数字: ' choice
    case "$choice" in
      1) menu_routes ;;
      2) menu_protocols ;;
      3) menu_config_actions ;;
      4) menu_xray ;;
      5) menu_exec cmd_status || true; menu_pause ;;
      6) menu_pair_manage ;;
      7) menu_exits ;;
      8) menu_self_update ;;
      0) return ;;
      *) warn "请输入菜单中已有的数字"; sleep 1 ;;
    esac
  done
}

cmd_menu() {
  [[ -t 0 && -t 1 ]] || die "交互菜单需要在终端中运行"
  local choice
  while true; do
    menu_header
    printf '%s常用功能%s\n' "$C_BOLD" "$C_RESET"
    printf '1. 🚀 第一次安装：这台是主服务器\n'
    printf '2. 🔗 第一次安装：这台是从服务器\n'
    printf '3. ➕ 给主服务器添加从服务器\n'
    printf '4. 👤 用户和订阅\n'
    printf '5. 📋 直接复制当前订阅\n'
    printf '6. 🩺 一键检查与修复\n'
    printf '7. ⚙  高级设置             （一般不用）\n'
    printf '8. ⬆  检查并更新 ETXR\n'
    printf '9. ↗  出口分流设置          （SOCKS5 / 远程出口）\n'
    printf '10. 📦 配置迁移             （加密导出 / 新服务器导入）\n'
    printf '0. 退出\n\n'
    read -r -p '请输入数字: ' choice
    case "$choice" in
      1) menu_quick_init ;;
      2) menu_worker_join ;;
      3) menu_pair_create ;;
      4) menu_users ;;
      5) menu_quick_subscription ;;
      6) menu_health_check ;;
      7) menu_advanced ;;
      8) menu_self_update ;;
      9) menu_exits ;;
      10) menu_migration ;;
      0)
        printf '%s已退出。%s\n' "$C_GREEN" "$C_RESET"
        return
        ;;
      *) warn "请输入 0～10 之间的数字"; sleep 1 ;;
    esac
  done
}

main() {
  parse_common_flags "$@"
  set -- "${REMAINING_ARGS[@]}"
  local command="${1:-}"
  shift || true
  if [[ -z "$command" ]]; then
    if [[ -t 0 && -t 1 ]]; then
      cmd_menu
    else
      usage
    fi
    return
  fi
  case "$command" in
    menu) cmd_menu ;;
    init) cmd_init "$@" ;;
    user) cmd_user "$@" ;;
    domain) cmd_domain "$@" ;;
    route) cmd_route "$@" ;;
    exit) cmd_exit "$@" ;;
    reality) cmd_reality "$@" ;;
    hy2) cmd_hy2 "$@" ;;
    keys) cmd_keys "$@" ;;
    render) cmd_render "$@" ;;
    validate) cmd_validate "$@" ;;
    apply) cmd_apply "$@" ;;
    install) cmd_install "$@" ;;
    subscription|sub) cmd_subscription "$@" ;;
    subscriptions) cmd_subscriptions "$@" ;;
    client) cmd_client "$@" ;;
    backup) cmd_backup "$@" ;;
    migration) cmd_migration "$@" ;;
    status) cmd_status "$@" ;;
    xray) cmd_xray "$@" ;;
    self) cmd_self "$@" ;;
    cluster) cmd_cluster "$@" ;;
    pair) cmd_pair "$@" ;;
    control) cmd_control "$@" ;;
    version) echo "$VERSION" ;;
    help|-h|--help) usage ;;
    *) usage; die "Unknown command: $command" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ "${BASH_SOURCE[0]}" == /dev/fd/* ||
        "${BASH_SOURCE[0]}" == /proc/*/fd/* ]]; then
    if (( EUID == 0 )); then
      if (install_self_command "${BASH_SOURCE[0]}"); then
        log "已安装 etxr 命令；以后直接输入 etxr 即可打开菜单"
      else
        warn "临时运行成功，但 etxr 命令预安装失败；完成首次安装时会再次尝试"
      fi
    else
      warn "当前不是 root，暂未安装 etxr 命令"
    fi
  fi
  main "$@"
fi
