#!/usr/bin/env python3
"""Verify XHTTP certificate pins follow certificate trust, not HY2 mode."""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "etxr.sh"


def run_openssl(*arguments: str) -> None:
    subprocess.run(
        ["openssl", *arguments],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="etxr-agent-tls-") as raw:
        directory = pathlib.Path(raw)
        helper = directory / "control.py"
        authority = directory / "ca.pem"
        authority_key = directory / "ca-key.pem"
        leaf = directory / "leaf.pem"
        leaf_key = directory / "leaf-key.pem"
        leaf_csr = directory / "leaf.csr"
        extensions = directory / "leaf.ext"
        state = directory / "state.json"

        environment = dict(os.environ)
        environment["ETXR_CONTROL_HELPER"] = str(helper)
        subprocess.run(
            [str(SCRIPT), "control", "helper"],
            env=environment,
            check=True,
        )

        run_openssl(
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-subj", "/CN=ETXR Test CA", "-keyout", str(authority_key),
            "-out", str(authority),
        )
        run_openssl(
            "req", "-newkey", "rsa:2048", "-nodes",
            "-subj", "/CN=worker.example.com", "-keyout", str(leaf_key),
            "-out", str(leaf_csr),
        )
        extensions.write_text(
            "subjectAltName=DNS:worker.example.com\n", encoding="utf-8"
        )
        run_openssl(
            "x509", "-req", "-in", str(leaf_csr), "-CA", str(authority),
            "-CAkey", str(authority_key), "-CAcreateserial", "-days", "1",
            "-extfile", str(extensions), "-out", str(leaf),
        )
        leaf.write_text(
            leaf.read_text(encoding="ascii")
            + authority.read_text(encoding="ascii"),
            encoding="ascii",
        )

        state.write_text(
            json.dumps(
                {
                    "node": {
                        "name": "worker",
                        "domain": "worker.example.com",
                        "address": "worker.example.com",
                    },
                    "nginx": {
                        "tls_port": 443,
                        "certificate": str(leaf),
                        "pinned_peer_cert_sha256": "",
                    },
                    "xray": {
                        "routes": [
                            {
                                "name": "worker-xhttp",
                                "path": "/worker",
                                "port": 18000,
                            }
                        ]
                    },
                    "hysteria2": {"enabled": True, "insecure": True},
                }
            ),
            encoding="utf-8",
        )

        namespace = {}
        compiled = compile(
            helper.read_text(encoding="utf-8"), str(helper), "exec"
        )
        saved_cert_file = os.environ.get("SSL_CERT_FILE")
        os.environ["SSL_CERT_FILE"] = str(authority)
        try:
            exec(compiled, namespace)
            agent = namespace["Agent"](
                str(state),
                str(SCRIPT),
                str(directory / "usage.json"),
                str(directory / "domains.json"),
            )
            entry = agent.entry_snapshot()
            assert entry["nginx"]["pinned_peer_cert_sha256"] == ""
        finally:
            if saved_cert_file is None:
                os.environ.pop("SSL_CERT_FILE", None)
            else:
                os.environ["SSL_CERT_FILE"] = saved_cert_file

    print("control-agent-tls-test: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
