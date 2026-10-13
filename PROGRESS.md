# 迁移状态

## 当前状态

- 验证日期：2026-10-13；宿主 macOS 26.3.1（25D2128），Xcode 26.3（17C529）。
- 迁移分支：`codex/upstream-v2-migration`，独立 worktree。完整吸收上游 `35d8e8f2`，旧 Manager 源码及旧运行时已删除。
- 迁移代码已提交，尚未推送或合入 `develop`。已安装并启动已公证的 Launchpad 2.9.2；Core Bundle 和 helper 尚未安装，未创建或启动新 VM。原 checkout 仍在 `develop`，两处 WIP 保留。
- 使用者已退出旧 Manager，旧 VM 也已停止。旧应用、完整 VM 数据和设备身份原样保留；旧 amfidont 流程仍在运行。

## 已验证

- `VPhone` 完整 bundle 构建、`VPhoneLaunchpad` 构建、bundle admission 和 `codesign --verify --strict --deep` 通过。
- CoreKit：网络配置、tunnel 帧循环、TCP 转发、ZIP 共 66 项测试通过。
- SOCKS5：真实 TCP/UDP、guest 侧域名解析路径、半关闭、64 路并发、绑定失败回退、会话取消和 30 次启停通过；AddressSanitizer/UndefinedBehaviorSanitizer 未报错。
- SOCKS5 配置：非法输入、保存启用/禁用、重启恢复和保存失败回退通过。测试在 Mac 的临时文件和随机端口完成；没有使用运行中的 VM 或飞连。
- daemon：324 项逻辑检查、148 项维护规则检查及 13 项 parser 检查通过；Launchpad 的 host policy、launcher policy、bundle binding 和 control 测试通过。

## 必须保留的约束

- 本机关键路径是 **Mac → guest 内飞连 → 公司网络**。保留 guest TCP/IP SOCKS5，用 NAT 的固定 IP 与上游端口转发配置；服务默认关闭，通过 `network.socks5.set` 开启。
- **guest → Mac VPN** 使用上游 tunnel，仍需在对应公司电脑验证。当前 tunnel 的默认 DNS 只取全局首个 IPv4 resolver，不能凭本机网络单元测试认定公司 supplemental DNS 可用。
- 必须保留已认证的原设备；不重建、不 restore、不生成新身份。旧配置在临时副本中仅添加 schema 2 标记即可被新版 CLI 读取；原机器标识仍有效。启动兼容性尚待验证，详见 [旧 VM 导入研究](Research/Host/legacy_vm_import.md)。
- 旧 VM 在新运行时的启动、guest 协议、飞连认证/网络和硬件设置尚未验收；1337→1339 协议及旧 VM 禁用加速器的配置必须兼容。当前 macOS 26.3.1 也不是上游兼容表中明确列出的组合。
- 仅允许保留原数据和身份的迁移。未经副本验收，不改已认证原 VM 的固件、daemon 或硬件配置。只有实际验收成功才能合入 develop。

## 下一步

1. 在迁移分支实现旧 VM 的显式导入兼容：保留机器身份、磁盘/NVRAM/SEP/ROM、旧硬件设置与 guest 环境。
2. 对已停止 VM 的 APFS 副本验证，保持同一身份，且不与原 VM 同时启动；核对既有飞连认证和公司网络。
3. 验收成功后再将原 VM 注册或搬到 Launchpad 的库中，并合入 develop。此前保留旧启动方式。
