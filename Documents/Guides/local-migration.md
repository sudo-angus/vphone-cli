# 本地迁移与网络验收

本机在 2026-10-13 完成旧设备迁移验收。上游 `35d8e8f2` 已完整吸收，GUI 使用官方 Launchpad 2.9.2。`DefaultVM` 运行于 `~/.vphone/machines/DefaultVM`，绑定本地 Core `2.9.3-local.0b0ec0e1`；代码提交 `633111c7`。宿主 macOS 26.3.1、旧 guest iOS 26.1.0 实际启动通过，使用者处理飞连和 Surge 后确认正常。

## 保留的设备

`DefaultVM` 是原 `vm/` 的 APFS 副本，沿用原 Disk、NVRAM、SEP、ROM 和 machineIdentifier。ECID/UDID 已比对一致。原目录的设备状态未改，保留为回退；两者不能同时运行。

导入命令为 `vphone-cli vm import-legacy <旧目录> --name <名称>`，只针对已停止的旧机。它拒绝无效身份、缺失或链接状态文件、忙碌原机和覆盖已有机器。`--socks5-host-port <空闲端口>` 可将 host 回环 TCP 转发到旧 guest 的 1080；先确认端口未被其他服务占用。

旧配置记录 `legacyGuestEnvironment: true` 和 `paravirtualAcceleratorsEnabled: false`，由 host 适配旧 VSOCK 1337 协议。旧 guest daemon、hook 环境与固件保持不动；不发送 daemon 更新握手，不自动同步新环境。文件、剪贴板、HID/touch、应用列表/启动、位置、设置和摇一摇适配旧操作，新操作若不存在会明确拒绝。

不要对这台已认证设备执行 restore、`--new-identity` 或 `cfw update-environment`。缺失导入状态时会拒绝启动，不会生成替代设备状态。

## 本机：Mac → guest 飞连 → 公司网络

本机保留 NAT，飞连与 Surge 规则由使用者配置。

- 旧 guest 的直连 SOCKS5：`192.168.64.250:1080`，适合 Surge 的 TCP/UDP 使用。
- host 回环 TCP 转发：`127.0.0.1:1080`。UDP ASSOCIATE 返回 guest 地址上的临时端口，需要 Mac 直接访问 guest。
- 旧 daemon 保留原有 SOCKS 服务，不能调用新 `network.socks5.set/get`。新 daemon 上的服务才是默认关闭并通过该 API 持久化启用。
- 这条路径不需要 tunnel。若 host 代理把 VM 的外连重新送回同一 guest 的 SOCKS5，会形成循环；Surge 规则必须处理这条出网路径。

本轮自动验证了启动、身份、guest ping、应用列表，以及原状态未被修改。自动 SOCKS 探测遇过连接重置，随后使用者接手飞连/Surge 并反馈“一切正常”；公司网络的验收依据是使用者实测。后续不自动操作飞连、代理规则或重启当前 VM。

## 新 guest 的 SOCKS5

新的原生 daemon 保留 guest TCP/IP SOCKS5，支持 TCP CONNECT、UDP ASSOCIATE 和 guest DNS。示例仅适用于使用新 daemon 的测试设备：

```sh
vphone-launchpad-cli guest rpc test-vm network.socks5.set '{"port":1080}'
vphone-launchpad-cli guest rpc test-vm network.socks5.get
```

`port:0` 关闭监听并取消会话；1024–65535 开启指定端口。绑定失败保留原监听；配置在 guest 内持久化。地址、端口转发、UDP 可达性和实际公司访问仍需逐机验证。

## 其他电脑：guest → Mac VPN

采用上游 `tunnel`，按[上游网络指南](networking.md)设置。当前默认 DNS 只取 Mac 全局首个 IPv4 resolver，没有按域名选择 supplemental resolver；需在对应电脑验证公司 DNS、HTTPS、UDP 和 VPN 重连。必要时明确设置该电脑可达的公司 DNS。不能用本机 Mac → guest 飞连的验收替代反向路径测试。

## 本地改造与回退

| 本地改造 | 当前实现 |
| --- | --- |
| 旧 Manager | 源码删除，使用 Launchpad |
| vsock 卡死自动重启 | 删除，保留连接重连和手动停止/启动 |
| 新 daemon SOCKS5 | TCP/IP 直连，256 会话上限、fd 预留和持久化设置 |
| 摇一摇 | 原生注入，`input.shake` 和 Motion Sensors → Shake |
| camfix 核心进程保护 | 排除 SpringBoard、backboardd 和 watchdog 等进程 |
| 加速器 | 新 guest 使用上游默认；旧机导入保留禁用设置 |
| USB 转发/Python workaround | 删除旧封装，采用上游网络与端口转发 |
| 剪贴板、软键盘、应用/文件 UI | 使用上游界面，导入旧机走兼容控制协议 |

旧代码保留在 `codex/legacy-vphone-rollback`；合并后遗留的旧子模块和生成文件收在原 checkout 的 `.build/legacy-checkout-remnants-20261013/`，回退时可按原相对路径取回，没有删除。两处原始 WIP 的具名 stash 为：

`b55b68e59e26269a3c7ad4e26d5a44ed46db382e`

camfix 改动已迁入新实现；旧 HealthMonitor 随 Manager 退役，原改动仍可从 stash 取回。旧 Manager 应用已移出 `/Applications`，保留在原 checkout 的 `.build/legacy-checkout-remnants-20261013/VPhone.app`；旧 `vm/` 仍保留。回退前先停止正在运行的副本，避免同一设备身份同时在线；停止当前 VM 必须先通知使用者。

新固件摇一摇、全量 UI 功能和长时间稳定性尚未逐项实机验证。迁移验收后合入 `develop`，不因此自动移除旧设备备份或推送远端。
