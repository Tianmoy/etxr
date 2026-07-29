#!/usr/bin/env python3
"""End-to-end checks for the local authenticated limiter and usage meter."""

from __future__ import annotations

import asyncio
import json
import os
import pathlib
import socket
import struct
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]


def free_port(sock_type: int = socket.SOCK_STREAM) -> int:
    with socket.socket(socket.AF_INET, sock_type) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


async def wait_tcp(port: int) -> None:
    for _ in range(100):
        try:
            reader, writer = await asyncio.open_connection("127.0.0.1", port)
        except OSError:
            await asyncio.sleep(0.05)
            continue
        writer.close()
        await writer.wait_closed()
        return
    raise AssertionError("limiter did not start")


async def socks_auth(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    username: str,
    password: str,
) -> bool:
    writer.write(b"\x05\x01\x02")
    await writer.drain()
    assert await reader.readexactly(2) == b"\x05\x02"
    user = username.encode()
    secret = password.encode()
    writer.write(
        b"\x01" + bytes([len(user)]) + user + bytes([len(secret)]) + secret
    )
    await writer.drain()
    return await reader.readexactly(2) == b"\x01\x00"


def ipv4_target(port: int) -> bytes:
    return b"\x01\x7f\x00\x00\x01" + struct.pack("!H", port)


async def tcp_echo(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    finally:
        writer.close()
        await writer.wait_closed()


class UDPEcho(asyncio.DatagramProtocol):
    def connection_made(self, transport: asyncio.DatagramTransport) -> None:
        self.transport = transport

    def datagram_received(self, data: bytes, address: tuple[str, int]) -> None:
        self.transport.sendto(data, address)


async def exercise_limiter(helper: pathlib.Path, tmp: pathlib.Path) -> None:
    limiter_port = free_port()
    tcp_server = await asyncio.start_server(tcp_echo, "127.0.0.1", 0)
    tcp_port = int(tcp_server.sockets[0].getsockname()[1])
    loop = asyncio.get_running_loop()
    udp_transport, _ = await loop.create_datagram_endpoint(
        UDPEcho, local_addr=("127.0.0.1", 0)
    )
    udp_port = int(udp_transport.get_extra_info("sockname")[1])
    config = tmp / "limits.json"
    config.write_text(
        json.dumps(
            {
                "listen": "127.0.0.1",
                "port": limiter_port,
                "users": [
                    {
                        "name": "alice",
                        "password": "secret",
                        "up_mbps": 10,
                        "down_mbps": 10,
                    }
                ],
            }
        ),
        encoding="utf-8",
    )
    limiter = await asyncio.create_subprocess_exec(
        str(helper),
        "limiter",
        "--config",
        str(config),
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        await wait_tcp(limiter_port)

        bad_reader, bad_writer = await asyncio.open_connection(
            "127.0.0.1", limiter_port
        )
        assert not await socks_auth(
            bad_reader, bad_writer, "alice", "wrong-secret"
        )
        bad_writer.close()
        await bad_writer.wait_closed()

        reader, writer = await asyncio.open_connection("127.0.0.1", limiter_port)
        assert await socks_auth(reader, writer, "alice", "secret")
        writer.write(b"\x05\x01\x00" + ipv4_target(tcp_port))
        await writer.drain()
        reply = await reader.readexactly(10)
        assert reply[:2] == b"\x05\x00"
        writer.write(b"tcp-through-limiter")
        await writer.drain()
        assert await reader.readexactly(19) == b"tcp-through-limiter"
        writer.close()
        await writer.wait_closed()

        control_reader, control_writer = await asyncio.open_connection(
            "127.0.0.1", limiter_port
        )
        assert await socks_auth(
            control_reader, control_writer, "alice", "secret"
        )
        control_writer.write(b"\x05\x03\x00" + ipv4_target(0))
        await control_writer.drain()
        udp_reply = await control_reader.readexactly(10)
        assert udp_reply[:2] == b"\x05\x00"
        relay_port = struct.unpack("!H", udp_reply[-2:])[0]

        udp_client = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        udp_client.setblocking(False)
        payload = b"udp-through-limiter"
        packet = b"\x00\x00\x00" + ipv4_target(udp_port) + payload
        await loop.sock_sendto(
            udp_client, packet, ("127.0.0.1", relay_port)
        )
        response = await asyncio.wait_for(
            loop.sock_recv(udp_client, 65536), timeout=3
        )
        assert response.endswith(payload)
        udp_client.close()
        control_writer.close()
        await control_writer.wait_closed()
    finally:
        limiter.terminate()
        await limiter.wait()
        tcp_server.close()
        await tcp_server.wait_closed()
        udp_transport.close()


async def exercise_meter(helper: pathlib.Path, tmp: pathlib.Path) -> None:
    state = tmp / "state.json"
    usage = tmp / "usage.json"
    executable_suffix = ".exe" if os.name == "nt" else ""
    fake_xray = tmp / f"xray{executable_suffix}"
    fake_source = tmp / "fake-xray.go"
    state.write_text(
        json.dumps(
            {
                "users": [
                    {
                        "name": "alice",
                        "uuid": "11111111-1111-4111-8111-111111111111",
                        "usage_epoch": "epoch-1",
                    }
                ],
                "data_plane": {"xray_api_port": 18182},
                "hysteria2": {"enabled": True},
            }
        ),
        encoding="utf-8",
    )
    fake_source.write_text(
        """package main

import "fmt"

func main() {
	fmt.Print(`{"stat":[
		{"name":"user>>>alice@hk>>>traffic>>>uplink","value":"1000"},
		{"name":"user>>>alice@hy2>>>traffic>>>downlink","value":"2000"},
		{"name":"user>>>relay@worker>>>traffic>>>uplink","value":"9999"}
	]}`)
}
""",
        encoding="utf-8",
    )
    subprocess.run(
        ["go", "build", "-o", str(fake_xray), str(fake_source)],
        env={**os.environ, "GOFLAGS": "-buildvcs=false"},
        check=True,
        cwd=ROOT,
    )
    process = await asyncio.create_subprocess_exec(
        str(helper),
        "meter",
        "--state",
        str(state),
        "--usage-file",
        str(usage),
        "--xray-bin",
        str(fake_xray),
        "--once",
    )
    assert await process.wait() == 0
    ledger = json.loads(usage.read_text(encoding="utf-8"))
    assert ledger["users"]["alice"]["uplink"] == 1000
    assert ledger["users"]["alice"]["downlink"] == 2000
    assert "relay" not in ledger["users"]

    state_value = json.loads(state.read_text(encoding="utf-8"))
    state_value["users"][0]["usage_epoch"] = "epoch-2"
    state.write_text(json.dumps(state_value), encoding="utf-8")
    process = await asyncio.create_subprocess_exec(
        str(helper),
        "meter",
        "--state",
        str(state),
        "--usage-file",
        str(usage),
        "--xray-bin",
        str(fake_xray),
        "--once",
    )
    assert await process.wait() == 0
    reset = json.loads(usage.read_text(encoding="utf-8"))
    assert reset["users"]["alice"]["usage_epoch"] == "epoch-2"
    assert reset["users"]["alice"]["uplink"] == 1000
    assert reset["users"]["alice"]["downlink"] == 2000


async def run() -> None:
    with tempfile.TemporaryDirectory(prefix="etxr-data-test-") as raw_tmp:
        tmp = pathlib.Path(raw_tmp)
        executable_suffix = ".exe" if os.name == "nt" else ""
        helper = tmp / f"etxr-dataplane{executable_suffix}"
        build = await asyncio.create_subprocess_exec(
            "go",
            "build",
            "-buildvcs=false",
            "-ldflags",
            "-s -w -X main.version=0.12.0",
            "-o",
            str(helper),
            "./cmd/etxr-dataplane",
            cwd=ROOT,
        )
        assert await build.wait() == 0
        version = await asyncio.create_subprocess_exec(
            str(helper),
            "version",
            stdout=asyncio.subprocess.PIPE,
        )
        stdout, _ = await version.communicate()
        assert version.returncode == 0
        assert stdout.decode().strip() == "0.12.0"
        await exercise_limiter(helper, tmp)
        await exercise_meter(helper, tmp)


def main() -> int:
    asyncio.run(run())
    print("data-plane-test: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
