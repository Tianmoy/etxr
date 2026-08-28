#!/usr/bin/env python3
"""Smoke-test the interactive numbered menu in a pseudo terminal."""

from __future__ import annotations

import os
import pathlib
import pty
import select
import signal
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "etxr.sh"


def main() -> int:
    pid, fd = pty.fork()
    if pid == 0:
        env = os.environ.copy()
        env["TERM"] = "xterm"
        os.execve(str(SCRIPT), [str(SCRIPT), "menu"], env)

    output = bytearray()
    sent = False
    deadline = time.monotonic() + 8
    status = None
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([fd], [], [], 0.2)
            if ready:
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    chunk = b""
                if not chunk:
                    break
                output.extend(chunk)
                if not sent and "请输入数字".encode() in output:
                    # Enter advanced settings, return to the beginner home,
                    # then exit. Queued PTY input keeps the smoke test stable.
                    os.write(fd, b"7\n0\n0\n")
                    sent = True
            done, wait_status = os.waitpid(pid, os.WNOHANG)
            if done:
                status = wait_status
                break
        if status is None:
            os.kill(pid, signal.SIGTERM)
            _, status = os.waitpid(pid, 0)
    finally:
        os.close(fd)

    text = output.decode("utf-8", errors="replace")
    assert "ETXR 简易管理面板" in text, text
    assert "用户和订阅" in text, text
    assert "这台是主服务器" in text, text
    assert "这台是从服务器" in text, text
    assert "给主服务器添加从服务器" in text, text
    assert "这台是 A" not in text, text
    assert "这台是 B" not in text, text
    assert "一键检查与修复" in text, text
    assert "检查并更新 ETXR" in text, text
    assert "出口分流设置" in text, text
    assert "配置迁移" in text, text
    assert "高级设置" in text, text
    assert "Xray 启停、日志、监控和更新" in text, text
    assert sent, text
    assert "已退出" in text, text
    assert os.waitstatus_to_exitcode(status) == 0, text
    print("menu-smoke-test: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
