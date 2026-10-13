# 本地分支迁移与网络验收

迁移分支 `codex/upstream-v2-migration` 完整合并上游 `35d8e8f26ea03f8b2c935452e7bc8d016f5d9654`，GUI 使用上游 VPhone Launchpad。旧 Manager、Python TCP/DNS workaround、amfidont supervisor、usbmux 转发器和 SOCKS5 vsock 数据通道已删除。迁移通过验收后才能合入 `develop`。

## 保留与替代

| 本地改造 | 当前实现 |
| --- | --- |
| Mac 通过 guest 内飞连访问公司网络 | guest TCP/IP SOCKS5，支持 TCP CONNECT 和 UDP ASSOCIATE；域名由 guest 解析 |
| guest 通过 Mac 的 VPN 出网 | 上游 `tunnel`；须在对应公司电脑验证 DNS 和 HTTP，不凭模式名称认定兼容 |
| SOCKS5 导致文件句柄耗尽 | 提升 daemon 软上限，限制 256 个 SOCKS5 会话，为控制 API 和文件操作预留空间 |
| 摇一摇 | `input.shake` RPC 和 VM 窗口的 Motion Sensors → Shake；复用原生注入实现 |
| libcamfix 核心进程保护 | 在 constructor 排除 SpringBoard、backboardd、assertiond、runningboardd、watchdogd、powerd |
| 剪贴板、软键盘、应用管理、日志、固件缓存 | 使用上游实现 |
| 禁用 VT/ANE 的临时改造 | 使用上游的 paravirt user-client 修复及完整加速器配置，启动验收须确认没有旧错误 |
| EXC_GUARD 的开发固件补丁 | 使用上游 patch catalogue；现有声明限定 iOS 18，不复制旧 dev variant |
| SSH/RPC 转发 | 使用上游 `--forward`；USB 工具仍可使用外部 `iproxy`，不另写 usbmux 实现 |
| vsock 卡死自动重启 | 删除旧 Manager 的自动恢复；上游负责 guest 控制连接重连，实际 VM 故障由 Launchpad 手动停止/启动 |

## 保护现有 VM

必须保留已认证的旧设备。上游只接受 schema 2，但这不证明必须重建：旧配置的临时副本仅添加版本标记便可被新版 CLI 读取，原机器标识仍有效。旧 VM 导入需要处理 guest 协议和硬件设置，详见 [导入研究](../../Research/Host/legacy_vm_import.md)。未经副本验收，不修改原配置、daemon 或固件；不执行 restore 或生成新身份。保留旧 checkout、`/Applications/VPhone.app` 和完整原 VM 作为回退路径。

新 bundle 在隔离 worktree 的 `.build/XcodeBundle/Build/Products/Debug/VPhone.bundle`，构建不会安装它。后续先用已停止旧 VM 的 APFS 副本验证兼容，保留同一设备身份，且不与原 VM 同时运行。准备停当前 VM 或切换代理时先征得使用者同意；不要结束旧 amfidont、VM 或 Manager 进程。

本地 Core Bundle 可按 [Launchpad CLI 指南](launchpad-cli.md)通过 `bundle install-local` 安装。优先使用已公证的上游 Launchpad 2.9.2，兼容本分支的 2.9.x bundle。编译出来的 Launchpad 未签名；没有 Developer ID 配置时不能安装它的 SMJobBless helper。

## Mac → guest 飞连 → 公司网络

这台电脑采用 `nat`。以下是完成旧 VM 导入兼容后的副本验收示例，`corp-test` 是副本名称；当前尚未完成导入实现，不能直接套用到已认证原设备。

```sh
# 只对验收副本配置；原设备地址和代理设置保留用于回退。
vphone-launchpad-cli exec vm config corp-test --network nat --ip 192.168.64.249 --forward tcp:11080:1080
vphone-launchpad-cli vm launch corp-test
# 核对副本已有的飞连与设备认证；不重新注册为新设备。
vphone-launchpad-cli guest rpc corp-test network.socks5.set '{"port":1080}'
vphone-launchpad-cli guest rpc corp-test network.socks5.get
```

服务默认关闭。`port:0` 关闭监听并取消现有会话；1024–65535 开启指定端口。配置保存于 guest 的 `/var/root/Library/Preferences/com.vphone.vphoned.socks5.plist`，重启后恢复。绑定失败会保留原监听，状态中的 `enabled`/`port` 是实际运行值，`saved_port` 是保存值。

先确认 `.249` 在该电脑没有被其他设备占用，实际 NAT 网段也可能不是 `192.168.64.0/24`。地址以该电脑的共享网络和 `device.network` 为准。

TCP 客户端可以继续连 Mac 回环端口。使用 `--socks5-hostname` 让域名在 guest 内解析，避免 Mac 的 DNS 掩盖问题：

```sh
curl --noproxy '' --socks5-hostname 127.0.0.1:11080 --connect-timeout 10 --max-time 30 -I https://example.com
# 将 URL 换成平时必须访问的公司地址；不要把令牌放进命令行。
curl --noproxy '' --socks5-hostname 127.0.0.1:11080 --connect-timeout 10 --max-time 30 -I 'https://<公司地址>'
```

Surge 等需要 UDP 的客户端优先直连 `192.168.64.249:1080`。UDP ASSOCIATE 返回 guest IP 上的临时端口，Mac 必须能直接访问该地址；`tunnel` 下单独转发 TCP 1080 不能满足这一点，因此本机使用 `nat`。服务无身份认证，直连地址只用于受信任的虚拟网络，不配置到公网可达的 bridged 接口。

验收顺序：

1. 公司域名 DNS、公司 HTTPS 和公网 HTTPS 均可用；公司页面可以返回登录跳转或 401/403，但必须区分应用授权和网络连接失败。
2. UDP 客户端通过代理完成一次 DNS 查询及业务需要的 UDP/QUIC 请求；不能用 curl 的 TCP 结果代替。
3. 同时访问多个页面/下载文件，并通过 guest RPC 列文件、读取设备信息，确认 daemon 未被代理占满。
4. 只断开测试 guest 内飞连，公司访问应失效；重新连接后新会话应恢复。飞连的全隧道/分流策略以公司配置为准。
5. 新 guest 重启后，`network.socks5.get` 应显示恢复的端口，公司网络仍可访问。测试期间旧 host 1080 不变。
6. 使用者允许切换后，才将日常代理端点从旧 VM 切到新 VM，再验证一轮；失败即切回旧端点。

## guest → Mac VPN → 公司网络

在需要此方向的电脑、新 VM 上设置 `--network tunnel`，按 [上游网络指南](networking.md)启动。用 `device.network` 确认 guest IPv4，再运行 `network.resolve` 验证公司域名，在 guest 浏览器访问同一个公司 HTTPS 地址与公网地址。宿主侧确认这些连接属于 `vphone-vm`，公司 VPN/代理规则实际接管该进程。

需要单独检查公司 DNS：当前 tunnel 只从 `State:/Network/Global/DNS` 取第一个 IPv4 resolver，没有按域名匹配 macOS 的 supplemental resolver。只在 `scutil --dns` 的 scoped/supplemental 条目中发布公司 DNS 的 VPN，不能直接认定兼容。必要时用 `vm config <新VM> --dns <可达的公司DNS IPv4>` 明确指定，然后再次验证公司和公网解析、VPN 重连后的恢复。这些测试通过后才可确认该电脑不再需要旧 workaround。

若 Mac 的代理又把 `vphone-vm` 流量送回同一台 guest 的 SOCKS5，会形成循环。两个方向应分别验收，代理规则须为该 VM 的出网选择直接线路或宿主 VPN。

## 其他验收与合入条件

导入旧 VM 的副本必须完成启动、设备身份比对、guest ping、既有飞连认证、公司网络访问、应用管理、剪贴板、软键盘、摇一摇、长时间运行和重启。查看日志是否出现旧的 VideoToolbox `-19093` / VM stopped unexpectedly。新固件的摇一摇尚未实际验证；没有可注入的前台用户 app 时它会报告错误。

通过以上验收后，才合入 `develop` 并移除旧安装与旧数据。旧 Manager 的源码已经删除，当前正在使用的已安装 Manager 保留到切换成功。
