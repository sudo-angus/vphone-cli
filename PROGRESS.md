# 迁移状态

## 当前状态

- 验证日期：2026-10-13；宿主 macOS 26.3.1（25D2128），Xcode 26.3（17C529）。
- 迁移分支：`codex/upstream-v2-migration`，独立 worktree。完整吸收上游 `35d8e8f2`，旧 Manager 源码及旧运行时已删除。
- 代码已提交；尚未推送、安装、合入 `develop`，也没有启动新 VM。原 checkout 仍在 `develop`，两处 WIP 保留。
- 当前旧 VM、已安装的旧 Manager、旧代理端点和 amfidont 流程保持运行，作为日常环境和回退路径。

## 已验证

- `VPhone` 完整 bundle 构建、`VPhoneLaunchpad` 构建、bundle admission 和 `codesign --verify --strict --deep` 通过。
- CoreKit：网络配置、tunnel 帧循环、TCP 转发、ZIP 共 66 项测试通过。
- SOCKS5：真实 TCP/UDP、guest 侧域名解析路径、半关闭、64 路并发、绑定失败回退、会话取消和 30 次启停通过；AddressSanitizer/UndefinedBehaviorSanitizer 未报错。
- SOCKS5 配置：非法输入、保存启用/禁用、重启恢复和保存失败回退通过。测试在 Mac 的临时文件和随机端口完成；没有使用运行中的 VM 或飞连。
- daemon：324 项逻辑检查、148 项维护规则检查及 13 项 parser 检查通过；Launchpad 的 host policy、launcher policy、bundle binding 和 control 测试通过。

## 必须保留的约束

- 本机关键路径是 **Mac → guest 内飞连 → 公司网络**。保留 guest TCP/IP SOCKS5，用 NAT 的固定 IP 与上游端口转发配置；服务默认关闭，通过 `network.socks5.set` 开启。
- **guest → Mac VPN** 使用上游 tunnel，仍需在对应公司电脑验证。当前 tunnel 的默认 DNS 只取全局首个 IPv4 resolver，不能凭本机网络单元测试认定公司 supplemental DNS 可用。
- schema 1 VM 不做原地升级。新 VM 使用 schema 2；不要更新旧 guest 的 daemon、改写旧 config 或复制使用中的 Disk.img。
- 新 VM 的启动、飞连登录/网络、摇一摇、camfix、加速器、长时间运行与重启均未实际验收。当前 macOS 26.3.1 也不是上游兼容表中明确列出的组合。
- 停旧 VM、安装新 bundle/helper、切换代理或删除旧安装之前，先让使用者安排切换。只有实际验收成功才能合入 develop。

## 下一步

1. 使用者允许测试切换后，按 [迁移与网络验收](Documents/Guides/local-migration.md) 安装已公证的上游 Launchpad 和本地 Core Bundle，新建独立 VM，保留旧 VM 回退。
2. 在新 guest 配置飞连，测试 host 11080 / 独立 guest IP；核对公司 DNS、HTTPS、UDP、代理并发、guest API、重连和重启。
3. 验收通过后再合入 develop；旧 Manager 的已安装应用及旧数据此后才删除。

## 证据

- 功能与切换步骤：[local-migration.md](Documents/Guides/local-migration.md)。
- 构建与测试日志：`/private/tmp/vphone-upstream-audit.5MLxkd/`；`.build/XcodeKitTests/Logs/Test/` 保存网络测试 xcresult。
- bundle：`.build/XcodeBundle/Build/Products/Debug/VPhone.bundle`；Launchpad：`.build/XcodeLaunchpad/Build/Products/Debug/vphone-launchpad.app`（未签名、未安装）。
