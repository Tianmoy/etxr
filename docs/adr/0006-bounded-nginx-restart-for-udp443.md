# ADR-0006: UDP 443 释放失败时执行一次受限 nginx 重启

- 日期：2026-09-07
- 状态：已接受

## 背景

Hysteria2 与网站共用 443 时，nginx 继续使用 TCP 443，Hysteria2 使用 UDP 443。
关闭 nginx H3/QUIC 后，reload 是异步的；宝塔 nginx 的旧 worker 可能长时间持有
QUIC socket，导致 sing-box 无法绑定 UDP 443。此前 ETXR 等待 30 秒后只能回滚。

## 决策

reload 并确认实际加载配置不再含 H3/QUIC 后，先等待旧 worker 最多 30 秒释放
UDP 443。仍被 nginx 占用时执行一次完整重启：systemd 管理的 nginx 使用
`systemctl restart nginx`；宝塔 nginx 必须找到唯一 master，向它发送 `TERM`，
确认 nginx 进程退出后用检测到的二进制重新启动。重启后仍占用、启动失败或 master
归属不明确时恢复原配置并停止应用。

## 备选方案

- 始终要求用户手动重启：可靠但不满足一键安装目标。
- reload 前直接完整重启：会让每次应用都中断 TCP 443。
- 强制杀死所有 nginx 进程：可能误伤用户自建或第二套 nginx，不可恢复风险过高。

## 后果

- 正面影响：宝塔旧 worker 滞留 QUIC socket 时可以自动完成 HY2 共用 UDP 443。
- 负面影响：该兜底路径会造成一次短暂 TCP 443 中断。
- 风险与后续：多 master 或非预期进程布局会拒绝自动处理，需要用户手动整理 nginx。
