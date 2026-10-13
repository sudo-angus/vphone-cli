# 迁移状态

## 当前运行状态

- 2026-10-13，本机旧 VM 在新版 Launchpad 下验收通过。宿主 macOS 26.3.1（25D2128），guest iOS 26.1.0，Xcode 26.3（17C529）。这是本机这台旧设备的实测组合，不扩展为所有固件的兼容保证。
- Launchpad 2.9.2 和 helper 16 已安装。运行中的 `DefaultVM` 位于 `~/.vphone/machines/DefaultVM`，绑定 Core `2.9.3-local.0b0ec0e1`（代码提交 `633111c7`）。Launchpad 启动后 23 秒完成旧 guest 握手。
- 完整吸收上游 `35d8e8f2`；旧 Manager 源码和旧运行时已删除。迁移分支 `codex/upstream-v2-migration` 验收后快进合入 `develop`；尚未推送。
- 原 `vm/` 的配置、NVRAM、SEP、ROM 指纹未变，磁盘通过 APFS CoW 保留为副本；ECID/UDID 与原设备一致。原设备保持停止，原目录和 `/Applications/VPhone.app` 留作回退，禁止与副本同时启动。
- 使用者接手飞连和 Surge 配置后反馈“一切正常”；这是本机认证与日常网络的人工验收。自动 SOCKS 探测曾遇连接重置，未将它记录为自动公司网络测试通过。后续飞连和 Surge 规则由使用者处理。

## 实现与验证

- 旧 VM 显式目录导入保留身份、Disk/NVRAM/SEP/ROM；拒绝无效身份、缺失或链接状态文件、忙碌原机和覆盖目的目录。旧环境保持不动，由 host 兼容 VSOCK 1337；禁用旧机已禁用的加速器，使用软件键盘。
- `VPhone` 完整签名 bundle、Launchpad 构建、bundle admission、安装 policy 和 host preflight 通过。
- 旧导入/协议/manifest 20 项针对性测试通过；副本两次实际启动、guest ping 和应用列表通过，飞连仍安装并运行。
- 网络/tunnel/TCP/ZIP 66 项测试通过；新 daemon SOCKS5 的 TCP/UDP、域名、半关闭、64 路并发、绑定回退、取消、30 次启停及 ASAN/UBSAN 通过。daemon 324 项逻辑、148 项维护规则、13 项 parser 检查和 Launchpad policy/binding/control 测试通过。
- 本机使用 NAT。保留旧 guest 的直连 SOCKS5 `192.168.64.250:1080`，增加 host TCP 回环 `127.0.0.1:1080` 转发。旧 guest 不使用新的 `network.socks5.set` API；新 daemon 的 SOCKS5 默认为关闭。
- 其他电脑的 guest → Mac VPN 路径采用上游 tunnel，需在那里验证公司 supplemental DNS、HTTP 与 UDP；本机验收不能证明那条路径。
- 新固件的摇一摇、全量 UI 功能和长时间稳定性尚未逐项实机验证。不会为此自动重启当前设备或更新已认证 guest。

## 回退与原始改动

- 旧代码保留在 `codex/legacy-vphone-rollback`，原两处未提交改动保留在具名 Git stash（见迁移指南）。camfix 的核心进程排除已迁入新代码；旧 HealthMonitor 的改动随 Manager 退役，保留备份。
- 不对当前已认证 VM 执行 restore、CFW 环境更新或身份重建。需要停止、切回旧机或变更当前代理时先通知使用者。
