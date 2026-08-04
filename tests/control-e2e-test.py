#!/usr/bin/env python3
"""End-to-end test for the embedded control hub and worker agent."""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import os
import pathlib
import socket
import sys
import tempfile
import time

import aiohttp

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "etxr.sh"
TOKEN = "a" * 64
NODE = "worker1"


def write_json(path: pathlib.Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, separators=(",", ":")) + "\n", encoding="utf-8")


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


async def wait_until(predicate, timeout: float = 8.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        await asyncio.sleep(0.1)
    raise AssertionError("timed out waiting for control-plane state")


async def receive_update(ws: aiohttp.ClientWebSocketResponse, version: str) -> None:
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        message = await ws.receive(timeout=2)
        assert message.type == aiohttp.WSMsgType.TEXT, message
        payload = json.loads(message.data)
        if payload.get("type") == "update" and payload.get("version") == version:
            return
    raise AssertionError(f"update {version} was not received")


async def run() -> None:
    with tempfile.TemporaryDirectory(prefix="etxr-control-test-") as raw_tmp:
        tmp = pathlib.Path(raw_tmp)
        helper = tmp / "control.py"
        state = tmp / "master-state.json"
        control = tmp / "control"
        desired = control / "nodes" / f"{NODE}.json"
        refresh_log = tmp / "subscription-refresh.log"
        fake_hub_etxr = tmp / "fake-hub-etxr"
        port = free_port()

        env = dict(os.environ)
        env["ETXR_CONTROL_HELPER"] = str(helper)
        extract = await asyncio.create_subprocess_exec(
            str(SCRIPT), "control", "helper", env=env
        )
        assert await extract.wait() == 0

        write_json(state, {"paired_nodes": [{"name": NODE, "control_token": TOKEN}]})
        users = [{
            "name": "alice",
            "uuid": "11111111-1111-4111-8111-111111111111",
            "hy2_password": "ALICEPASS",
            "enabled": True,
            "expires_at": None,
            "routes": ["*"],
            "subscription_prefix": "522b276a",
            "subscription_token": "1" * 40,
            "domain_epoch": "domain-epoch-1",
        }]
        domain_audit = {
            "enabled": True,
            "retention_days": 30,
            "max_domains_per_user": 500,
        }
        issued_at = int(time.time())
        write_json(desired, {
            "node_id": NODE,
            "version": "v1",
            "issued_at": issued_at,
            "users": users,
            "domain_audit": domain_audit,
        })
        fake_hub_etxr.write_text(
            "#!/usr/bin/env bash\n"
            "printf '%s\\n' \"$*\" >>\"$ETXR_TEST_REFRESH_LOG\"\n",
            encoding="utf-8",
        )
        fake_hub_etxr.chmod(0o755)
        hub_env = dict(os.environ)
        hub_env["ETXR_TEST_REFRESH_LOG"] = str(refresh_log)
        write_json(control / "reports" / f"{NODE}.json", [])

        hub = await asyncio.create_subprocess_exec(
            sys.executable,
            str(helper),
            "hub",
            "--state",
            str(state),
            "--control-dir",
            str(control),
            "--etxr-bin",
            str(fake_hub_etxr),
            "--subscription-dir",
            str(tmp / "subscriptions"),
            "--listen",
            "127.0.0.1",
            "--port",
            str(port),
            env=hub_env,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )
        base_url = f"http://127.0.0.1:{port}"
        try:
            async with aiohttp.ClientSession() as session:
                for _ in range(50):
                    try:
                        async with session.get(f"{base_url}/health") as response:
                            if response.status == 200:
                                break
                    except aiohttp.ClientError:
                        pass
                    await asyncio.sleep(0.1)
                else:
                    raise AssertionError("control hub did not start")

                async with session.get(f"{base_url}/config/{NODE}") as response:
                    assert response.status == 401

                headers = {"Authorization": "Bearer " + TOKEN}
                entry = {
                    "schema": 1,
                    "node": {
                        "name": NODE,
                        "domain": "worker.example.com",
                        "address": "worker.example.com",
                    },
                    "nginx": {"tls_port": 443},
                    "xray": {"routes": [], "reality_inbounds": []},
                    "hysteria2": {"enabled": False},
                }
                async with session.post(
                    f"{base_url}/report/{NODE}",
                    headers=headers,
                    json={"status": "current", "entry": entry},
                ) as response:
                    assert response.status == 200
                await wait_until(refresh_log.exists)
                assert "subscriptions refresh" in refresh_log.read_text(encoding="utf-8")
                async with session.get(
                    f"{base_url}/config/{NODE}", headers=headers
                ) as response:
                    body = await response.read()
                    assert response.status == 200
                    expected = hmac.new(TOKEN.encode(), body, hashlib.sha256).hexdigest()
                    assert response.headers["X-ETXR-Signature"] == expected

                async with session.ws_connect(
                    f"{base_url}/ws/{NODE}", headers=headers
                ) as ws:
                    await receive_update(ws, "v1")
                    write_json(
                        desired,
                        {
                            "node_id": NODE,
                            "version": "v2",
                            "issued_at": issued_at + 1,
                            "users": users,
                            "domain_audit": domain_audit,
                        },
                    )
                    await receive_update(ws, "v2")

            worker = tmp / "worker"
            worker_state = worker / "state.json"
            payload_file = worker / "applied-users.json"
            usage_file = worker / "usage.json"
            domain_file = worker / "domains.json"
            fake_etxr = worker / "fake-etxr"
            write_json(worker_state, {
                "node": {
                    "name": NODE,
                    "domain": "worker.example.com",
                    "address": "worker.example.com",
                },
                "nginx": {"tls_port": 443},
                "xray": {"routes": [], "reality_inbounds": []},
                "hysteria2": {"enabled": False},
                "control": {"agent": {
                    "enabled": True,
                    "base_url": base_url,
                    "node_id": NODE,
                    "token": TOKEN,
                }}
            })
            fake_etxr.write_text(
                "#!/usr/bin/env bash\nset -Eeuo pipefail\ncat >\"$ETXR_TEST_PAYLOAD\"\n",
                encoding="utf-8",
            )
            fake_etxr.chmod(0o755)
            write_json(usage_file, {
                "updated_at": int(time.time()),
                "users": {
                    "alice": {
                        "uuid": users[0]["uuid"],
                        "usage_epoch": "",
                        "uplink": 1234,
                        "downlink": 5678,
                    }
                },
            })
            write_json(domain_file, {
                "schema": 1,
                "updated_at": int(time.time()),
                "node": NODE,
                "users": {
                    "alice": {
                        "uuid": users[0]["uuid"],
                        "domain_epoch": users[0]["domain_epoch"],
                        "unresolved": 2,
                        "domains": {
                            "example.com": {
                                "connections": 3,
                                "first_seen": int(time.time()) - 60,
                                "last_seen": int(time.time()),
                            }
                        },
                    }
                },
            })
            write_json(
                desired,
                {
                    "node_id": NODE,
                    "version": "v3",
                    "issued_at": issued_at + 2,
                    "users": users,
                    "domain_audit": domain_audit,
                },
            )
            agent_env = dict(os.environ)
            agent_env["ETXR_TEST_PAYLOAD"] = str(payload_file)
            agent = await asyncio.create_subprocess_exec(
                sys.executable,
                str(helper),
                "agent",
                "--state",
                str(worker_state),
                "--etxr-bin",
                str(fake_etxr),
                "--usage-file",
                str(usage_file),
                "--domain-file",
                str(domain_file),
                env=agent_env,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.PIPE,
            )
            try:
                version_file = worker / "control-version"
                issued_at_file = worker / "control-issued-at"
                report_file = control / "reports" / f"{NODE}.json"
                await wait_until(
                    lambda: version_file.exists()
                    and version_file.read_text(encoding="utf-8").strip() == "v3"
                    and issued_at_file.exists()
                    and issued_at_file.read_text(encoding="utf-8").strip()
                    == str(issued_at + 2)
                    and payload_file.exists()
                    and report_file.exists()
                    and json.loads(report_file.read_text(encoding="utf-8")).get("status")
                    == "applied"
                )
                assert json.loads(payload_file.read_text(encoding="utf-8")) == {
                    "users": users,
                    "domain_audit": domain_audit,
                }
                report = json.loads(report_file.read_text(encoding="utf-8"))
                assert report["usage"]["users"]["alice"]["uplink"] == 1234
                assert report["usage"]["users"]["alice"]["downlink"] == 5678
                assert report["entry"]["node"]["name"] == NODE
                assert report["domains"]["node"] == NODE
                assert report["domains"]["users"]["alice"]["unresolved"] == 2
                domains = report["domains"]["users"]["alice"]["domains"]
                assert domains["example.com"]["connections"] == 3
            finally:
                agent.terminate()
                await agent.wait()
        finally:
            hub.terminate()
            await hub.wait()


def main() -> int:
    asyncio.run(run())
    print("control-e2e-test: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
