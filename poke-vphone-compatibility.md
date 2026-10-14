# Poke 与 vphone v2 兼容问题交接

2026-10-14；源码基线 `develop / 3222ab78`。宿主兼容代码、完整 bundle 构建与签名检查通过；已按使用者授权切换 Core，旧 guest 实机验收通过。

`DefaultVM` 当前绑定 `2.9.3-local.459fa1bb`，状态为 `running`，使用 NAT。guest 环境与设备身份保留；原 Core `2.9.3-local.0b0ec0e1` 仍保留，且仍为新机器的默认 Core。

## 原故障

新 guest 使用 VSOCK 1339 上的 HTTP/RPC；本机保留的 legacy guest 仍通过兼容层走 1337。现有 VSOCK 连接可用，故障集中在 Mac 的 `vphone.sock` 命令入口和截图路径。

- **启动失败**：Poke 发送 `app_launch`，新版宿主未保留该命令，只支持 `rpc → apps.launch`，返回 `unknown command: app_launch`。通过 Launchpad 的 `guest rpc DefaultVM apps.launch` 已成功启动 App。
- **独立截图失败**：宿主 `screenshot` 强制调用 guest 的 `screen.screenshot`，legacy guest 不支持，返回 `guest does not support capability: screen.screenshot`。点击后的截图使用宿主窗口捕获，已验证可用。
- **Poke 检测误报**：`capabilities` 写死支持上述功能；`doctor` 只确认 socket 返回响应，未检查 `ok=false`，因此错误地报告正常。

## 已实现

兼容层位于 vphone 宿主，沿用当前 guest RPC 和 VSOCK 1337 适配：

- `app_launch`、`app_terminate`、`app_uninstall`、`app_list`、`open_url`、`clipboard_set`、`clipboard_get` 转发到对应 RPC。应用列表、PID 和剪贴板文本保留在响应顶层；原 `rpc` 的结果仍放在 `result` 中。`app_uninstall` 本身视为卸载确认，对新版 guest 转为 `force:true`。
- `ipa_install` 接收宿主 IPA 路径，复用现有上传和 guest 安装逻辑，保留安装结果及可用的 `bundle_id`。这条路径仍绕过 installd。
- 独立截图与动作缩略图复用宿主显示捕获。有窗口时直接保存完整帧；无窗口时调用 guest 截图，guest 不支持时明确返回失败。PNG 直接编码完整帧，动作缩略图仍为 1/3 尺寸 JPEG；截图响应另含文件实际 `width`、`height`、`format`。
- guest 拒绝请求时保留 `ok:false`、错误文本和结构化 `guest_error`；legacy 回复中的 `ok:false` 也视为失败。

## 已验证

- `zsh VPhoneExecutable/VPhoneVirtualization/Tests/run-host-automation-tests.sh` 通过。使用生产 socket server、图片编码器和 legacy 回复解析器，以 guest/display 替身验证旧命令转发、参数缺失、响应结构、guest 拒绝、完整 PNG/JPEG、动作缩略图、截图写入失败，以及无窗口时的截图与错误处理。
- 现有 `/Users/angus/workspace/Project/self-working/poke/cli/.build/debug/poke` 在隔离 socket 上执行 `screenshot`、`launch_app`、`list_apps --filter running`、`set_clipboard`、`open_url`、`tap`、`doctor`，7 个命令均成功。4 张图片文件的实际格式和尺寸与 Poke 返回值一致：独立 PNG 为 1290×2796，动作 JPEG 为 430×932。这些是隔离测试结果，尚未证明真实 guest 中的 UI 行为。
- 完整 `VPhone` 构建、bundle admission 与 `codesign --verify --deep --strict` 通过。产物在 `.build/XcodeBundle/Build/Products/Debug/VPhone.bundle`，构建标记为 `3222ab78-dirty`。构建期间遇到的 Capstone 下载中断已通过同版本本地 checkout 恢复。

## 实机验收

- Launchpad 安装新 Core 后 policy/preflight 均通过；经使用者授权，停止 `DefaultVM`，绑定 `2.9.3-local.459fa1bb`，保留 guest 环境并重新启动。旧 guest 在 20 秒后握手完成，UDID 保持一致；`config.plist` 与切换前逐字节一致，`machineIdentifier` 的 SHA-256 也一致。
- 实际 Poke 的独立截图为 1290×2796 PNG；启动 Settings、列运行中应用、剪贴板写入/读回、`open_url prefs:`、点击后的截图均通过。截图中确认 Settings 已打开，点击 General 行后进入 General。动作图片为 430×932 JPEG，文件实际格式与尺寸均与 Poke 返回值一致。
- `terminate_app com.apple.Preferences` 成功，随后运行中列表已无 Settings；仅终止本次测试打开的 Settings。安装/卸载命令仅验证了宿主转发与参数/响应，未在这台认证设备上执行真实安装或卸载。
- 剪贴板测试后恢复原内容。首次启动请求因重启后的锁屏被 guest 拒绝，已用 Home 键解锁后完成启动验证；不存在的 bundle ID 返回 `ok:false` 和结构化 `guest_error`。
- 飞连仍在运行，host `127.0.0.1:1080` TCP 端口可连接。公司网络与 Surge 的实际业务访问仍需使用者确认；端口可连接不能证明 VPN 路由可用，本轮未更改飞连或 Surge 配置。
- 实机日志与 Poke JSON 留在 `.build/poke-compat-tests/`，宿主独立回归测试位于 `VPhoneExecutable/VPhoneVirtualization/Tests/`。

## Poke 后续工作

Poke 代码本轮未修改。它的 `doctor` 仍未检查宿主响应中的 `ok:false`，`capabilities` 仍为静态声明，屏幕尺寸也仍固定为 1290×2796。宿主兼容修复不能证明这些检测逻辑可靠。后续应适配新版 RPC、实际能力与图片尺寸，并补 guest 拒绝请求时的健康检查回归。

## 代码落点

- `VPhoneExecutable/VPhoneVirtualization/UI/VPhoneHostAutomationServer.swift`：`respond(to:)`、`case "screenshot"`、`case "rpc"`、`captureScreenImage()`。
- `VPhoneExecutable/VPhoneVirtualization/UI/HostDevices/VPhoneScreenRecorder.swift`：直接编码完整显示帧。
- `VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneGuestControl.swift`：IPA 上传、安装结果与新版 HTTP/RPC。
- `VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneLegacyGuestControl.swift`：1337 连接、legacy 方法映射与拒绝请求解析。
- `VPhoneExecutable/VPhoneVirtualization/Tests/run-host-automation-tests.sh`：宿主兼容回归；加 `--serve` 可启动 60 秒的隔离 socket，用于现有 Poke CLI 验证。
- Poke：`/Users/angus/workspace/Project/self-working/poke/cli/Sources/PokeCore/Backends/VPhoneBackend.swift`，重点看 `launchApp`、`setClipboard`、`screenshot`、`doctor`、`makeCapabilities`。

## 后续验证与回退

- 完成 Poke 后续改动后，验证 guest 拒绝请求时能力/健康状态不会误报成功；有新版 guest 可用时补实机回归。本轮新版 guest 的截图路径只做了替身测试。
- 若需回退，停止 `DefaultVM`，用 Launchpad 重新绑定 `2.9.3-local.0b0ec0e1` 后启动；保留 guest 环境，不使用 `--update-environment` 或 restore。后续重启仍应等设备空闲并取得使用者授权。
