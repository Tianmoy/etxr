#!/usr/bin/env python3
"""Static checks that do not require Linux services or proxy binaries."""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "etxr.sh"


def main() -> int:
    text = SCRIPT.read_text(encoding="utf-8")
    assert text.startswith("#!/usr/bin/env bash\n")
    assert "set -Eeuo pipefail" in text
    assert 'VERSION="0.13.2"' in text
    assert "local expires_minutes=30 expires_at" in text
    assert "--expires-minutes" in text

    # Supported protocol and routing features.
    assert 'protocol: ["bittorrent"]' in text
    assert '{protocol: "bittorrent", action: "reject"}' in text
    assert '"vlessenc-vision"' in text
    assert 'security: "reality"' in text
    assert 'type: "hysteria2"' in text
    assert "fallbackTag:" in text
    assert "observatory:" in text
    assert "proxy_request_buffering off" in text
    assert "render_nginx_stream()" in text
    assert "stream_ssl_preread_module" in text
    assert "grep -Evq '(^|[[:space:]])quic([[:space:];]|$)'" in text
    assert "aod.itunes.apple.com:443" in text
    assert "shared_tcp443" in text
    assert "shared_udp443" in text
    assert "--share-udp443" in text
    assert "nginx_quic_active_manifest()" in text
    assert "nginx_quic_disable_manifest()" in text
    assert "nginx_quic_restore_backup()" in text
    assert "nginx_tcp443_active_manifest()" in text
    assert "nginx_tcp443_rebind_manifest()" in text
    assert "nginx_tcp443_restore_backup()" in text
    assert "render_nginx_stream_loader()" in text
    assert "/etc/nginx/modules-enabled/99-etxr-stream.conf" in text
    assert "libnginx-mod-stream" in text
    assert "verify_hy2_udp_listener()" in text
    assert "# etxr-hy2-udp443:" in text
    assert "普通 HTTPS、HTTP/2 和 TCP 443 保持不变" in text
    assert "'/^(Password|PublicKey):/" not in text
    assert "'/^Password/" in text

    # Baota nginx and the beginner-oriented management menu.
    assert "/www/server/nginx/sbin/nginx" in text
    assert "cmd_menu()" in text
    assert "menu_xray()" in text
    assert "menu_health_check()" in text
    assert "menu_quick_subscription()" in text
    assert "menu_advanced()" in text
    assert "menu_pair_manage()" in text
    assert "menu_self_update()" in text
    assert "查看配置下发状态" in text
    assert "配置接收 Agent" in text
    assert "配置下发服务" in text
    assert "cmd_xray_update()" in text
    assert "cmd_self_update()" in text
    assert "download_etxr_release_script()" in text
    assert "ETXR Release 标签与脚本版本不一致" in text
    assert "download_xray_release()" in text
    assert "parse_xray_sha256_dgst()" in text
    assert "github_asset_sha256()" in text
    assert 'key == "SHA256" || key == "SHA2256"' in text
    assert "sing-box release 没有可用的 SHA256 摘要" in text
    assert "prompt_port_checked()" in text
    assert "prompt_worker_direct_config()" in text
    assert "--configure-direct" in text
    assert "--direct-config-file" in text
    assert "tls_certificate_is_usable()" in text
    assert "tls_certificate_matches_name()" in text
    assert "协议、域名、证书、Path 和 443 共用全部在从服务器上选择" in text
    assert "第一次安装：这台是主服务器" in text
    assert "第一次安装：这台是从服务器" in text
    assert "检查并更新 ETXR" in text
    assert "这台是 A" not in text
    assert "这台是 B" not in text

    # Public relay is primary when configured; EasyTier is the fallback.
    assert "cmd_pair_create()" in text
    assert "cmd_pair_join()" in text
    assert "install_easytier()" in text
    assert "EASYTIER_CONFIG=" in text
    assert "--config-file ${EASYTIER_CONFIG} --console-log-level warn" in text
    assert "network_secret =" in text
    assert "listeners = []" in text
    assert "[[peer]]" in text
    assert 'uri = "tcp://%s"' in text
    assert "private_mode = true" in text
    assert "enable_ipv6 = false" in text
    assert "enable_encryption = true" in text
    assert 'encryption_algorithm = "aes-gcm"' in text
    assert "--network-secret ${et_secret}" not in text
    assert re.search(
        r"\[network_identity\].*network_name.*network_secret.*"
        r"\[flags\].*private_mode",
        text,
        re.S,
    )
    assert "public-primary" in text
    assert "easytier-only" in text
    assert "--public-listen-port" in text
    assert "--xhttp-enabled" in text

    # The control plane shares nginx 443 through a random path and binds only
    # to localhost behind nginx. Worker pairing uses schema version 2.
    assert 'CONTROL_PORT="${ETXR_CONTROL_PORT:-18180}"' in text
    assert 'SYSTEMD_UNIT_DIR="${ETXR_SYSTEMD_UNIT_DIR:-/etc/systemd/system}"' in text
    assert "ETXR_CONTROL_HELPER_BEGIN" in text
    assert "ETXR_CONTROL_HELPER_END" in text
    assert "aiohttp" in text
    assert "WebSocketResponse" in text
    assert '"X-ETXR-Signature"' in text
    assert 'Authorization", ""' in text
    assert "hmac.compare_digest" in text
    assert "MAX_CONFIG_BYTES = 1024 * 1024" in text
    assert "refusing replayed configuration" in text
    assert "issued_at: $issued_at" in text
    assert "next_check = time.monotonic() + 300" in text
    assert "etxr-control.service" in text
    assert "etxr-agent.service" in text
    assert "--listen 127.0.0.1" in text
    assert "etxr-wait-ip" in text
    assert 'grep -Fq "inet ${ip_addr}/"' in text
    assert "ER2." in text
    assert "openssl pkeyutl -verify" in text
    assert "PAIR_ID_MAX_BYTES" in text
    assert "PAIR_BUNDLE_MAX_BYTES" in text
    assert "Do not parse attacker-controlled compressed content before authentication" in text
    assert "Unsafe TAR link entry" in text
    assert "Unsafe ZIP symlink entry" in text
    assert "self.validate_base_url(base_url)" in text
    assert "version: 2" in text
    assert "control_token" in text
    assert "cmd_control_apply()" in text
    assert "cmd_control_status()" in text
    assert "control apply|status" in text
    assert "cmd_user_limit()" in text
    assert "cmd_user_usage()" in text
    assert "cmd_user_reset_usage()" in text
    assert 'DATAPLANE_BIN="${ETXR_DATAPLANE_BIN:-/usr/local/bin/etxr-dataplane}"' in text
    assert "DATAPLANE_DOWNLOAD_BASE=" in text
    assert "ETXR_DOWNLOAD_BASE" in text
    assert "detect_arch_dataplane()" in text
    assert "etxr-dataplane-linux-${arch}" in text
    assert "ETXR 数据面 SHA256 校验失败" in text
    assert "ETXR_DATAPLANE_SOURCE" in text
    assert "data_plane.py" not in text
    assert "ETXR_DATA_HELPER_BEGIN" not in text
    assert "ETXR_DATA_HELPER_END" not in text
    assert "etxr-limiter.service" in text
    assert "etxr-meter.service" in text
    assert 'dialerProxy: ("limit-socks-" + $u.name)' in text
    assert 'inboundTag: ["hy2-bridge-in"]' in text

    # Subscriptions use a per-user SHA1 prefix and random token, never /sub/.
    assert r'"location = /\(.subscription_prefix)/\(.subscription_token)' in text
    assert 'subscription_prefix: $prefix' in text
    assert 'subscription_token: $token' in text
    assert 'location = /sub/' not in text
    assert 'install -m 600 "$GENERATED_DIR/nginx-paths.conf"' in text
    assert 'install -m 600 "$GENERATED_DIR/nginx-stream.conf"' in text

    # Public relay prompts must describe who connects to each port. A worker
    # with a dedicated public IP uses one public/listen port; only NAT mode
    # asks for separate external and internal ports.
    assert "客户端看到的公网中继 TCP 端口" not in text
    assert "从服务器公网中继 TCP 端口（需在防火墙放行）" in text
    assert 'backup_listen_port="$backup_port"' in text
    assert "服务商提供的公网映射 TCP 端口（外部端口）" in text
    assert "从服务器本机中继 TCP 端口（映射目标端口）" in text
    assert '--nginx-auto-rebind-https "$auto_rebind_https"' in text
    assert 'prefix="${master_ip%.*}"' in text
    assert 'candidate="${prefix}.${octet}"' in text
    assert '"10.100.0.${octet}"' not in text
    assert "(.worker.easytier_ip | subnet24) == (.master.easytier_ip | subnet24)" in text

    # Fresh-install-only code must not carry historical import or remote-shell
    # synchronization implementations.
    lowered = text.lower()
    for forbidden in (
        "edge" + "-router",
        "lega" + "cy_",
        "mig" + "rate",
        "authorized" + "_keys",
        "open" + "s" + "sh",
        "sync_paired_workers",
        "cmd_sync_apply",
    ):
        assert forbidden not in lowered, forbidden

    assert "/usr/local/sbin/etxr" in text
    assert not re.search(r"\+\s+if\b", text)

    # Every jq-generated JSON document must be parsed again by the runtime;
    # this catches accidental direct string-splicing in important render paths.
    for function in ("render_xray", "render_sing_box"):
        match = re.search(rf"^{function}\(\) \{{(.*?)(?=^\}}\n)", text, re.M | re.S)
        assert match, function
        assert "jq -n" in match.group(1)

    examples = list((ROOT / "examples").glob("*.sh"))
    assert examples
    for example in examples:
        assert "TARGET" not in example.read_text(encoding="utf-8")

    print("static-test: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
