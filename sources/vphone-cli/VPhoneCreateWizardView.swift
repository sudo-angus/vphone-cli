import SwiftUI

private func tr(_ en: String, _ zh: String) -> String { VPhoneL10n.tr(en, zh) }

/// The "New VM" wizard. Three states: a configuration step (name, variant,
/// hardware, iOS firmware), a progress step that tracks the orchestration
/// engine's phases while `setup_machine` runs, and a completion step that
/// walks the user through the first boot.
struct VPhoneCreateWizardView: View {
    @Bindable var model: VPhoneCreateModel
    var onDismiss: () -> Void

    var body: some View {
        Group {
            switch model.engine.status {
            case .idle: configStep
            case .done: doneStep
            default: progressStep
            }
        }
        .frame(width: 480, height: 580)
    }

    // MARK: - Config step

    private var configStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New vPhone").font(.headline)

            Form {
                Section("Name") {
                    TextField("Display name", text: $model.name)
                    LabeledContent("Folder") {
                        Text("vms/\(model.slug)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if model.targetExists {
                        Label("A VM with this name already exists", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Section("Variant") {
                    Picker("Firmware variant", selection: $model.variant) {
                        ForEach(VPhoneCreateModel.Variant.allCases) { v in Text(v.label).tag(v) }
                    }
                    Text(model.variant.blurb).font(.caption).foregroundStyle(.secondary)
                }
                Section("Hardware") {
                    Stepper("CPU cores: \(model.cpu)", value: $model.cpu, in: 2 ... 16)
                    Stepper("Memory: \(model.memoryMB) MB", value: $model.memoryMB, in: 2048 ... 32768, step: 1024)
                    Stepper("Disk: \(model.diskGB) GB", value: $model.diskGB, in: 16 ... 256, step: 16)
                }
                Section("iOS firmware") {
                    if model.catalog.isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading available versions…").foregroundStyle(.secondary)
                        }
                    } else if let err = model.catalog.error {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Picker("Version", selection: $model.selectedFirmware) {
                            ForEach(model.catalog.firmwares) { fw in
                                Text("\(fw.label) · \(fw.supportSummary)\(fw.ipswCached ? " · cached" : "")")
                                    .tag(Optional(fw))
                            }
                        }
                        Text("“Supported” = in the project's tested matrix, with the Mac it was tested on — only an actual boot + connect confirms a build works on yours. “cached” = IPSW already downloaded.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            .formStyle(.grouped)

            if let err = model.error {
                Text(err).font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") { Task { await model.beginCreate() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canCreate)
            }
        }
        .padding(20)
        .task { await model.loadFirmwares() }
    }

    // MARK: - Progress step

    private var progressStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Creating “\(model.name)”").font(.headline)
                Spacer()
                Text("vms/\(model.slug)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.engine.steps, id: \.phase) { step in
                    HStack(spacing: 8) {
                        stepIcon(step.status)
                        Text(step.phase.rawValue)
                            .foregroundStyle(step.status == .pending ? .secondary : .primary)
                        Spacer()
                    }
                    .font(.system(size: 13))
                }
            }
            .padding(10)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if !model.engine.detail.isEmpty {
                Text(model.engine.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            engineLog

            if let err = model.engine.error {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(3)
            }

            HStack {
                statusBadge
                Spacer()
                if model.engine.isRunning {
                    Button("Cancel", role: .destructive) { model.engine.cancel() }
                } else {
                    // Success switches to `doneStep`, so this only covers failed/cancelled.
                    Button("Close") { onDismiss() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
    }

    // MARK: - Done step (first-boot guide)

    /// Setup finished — the VM exists but has never booted. Walk the user
    /// through the first boot, and warn up front about the two setup-assistant
    /// traps (Apple Account sign-in, passcode) before they hit them.
    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("“\(model.name)” is ready", "「\(model.name)」已创建完成"))
                        .font(.headline)
                    Text("vms/\(model.slug)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(tr("NEXT STEPS", "接下来"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                guideRow(
                    number: 1,
                    text: tr(
                        "Select “\(model.name)” in the sidebar and click Start to boot it for the first time.",
                        "在左侧列表选中「\(model.name)」，点击 Start 进行第一次启动。"
                    )
                )
                guideRow(
                    number: 2,
                    text: tr(
                        "In the VM window, walk through the iOS setup assistant just like a new iPhone.",
                        "在虚拟机窗口中，按照新 iPhone 的初始化流程完成设置。"
                    )
                )
                guideRow(
                    number: 3,
                    text: tr(
                        "Once on the home screen: Settings → Display & Brightness → Auto-Lock → Never, so the screen stays on.",
                        "进入主屏幕后：设置 → 显示与亮度 → 自动锁定 → 永不，屏幕就不会自动熄灭。"
                    )
                )
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 13))
                    .padding(.top, 1)
                Text(tr(
                    "Apple Account sign-in is not supported in the VM — choose Skip at every sign-in step. Skip the passcode too, so the device boots straight to the home screen.",
                    "虚拟机内不支持登录 Apple 账户：初始化过程中所有登录步骤请一律选择「跳过」；也不要设置锁屏密码，这样每次启动都能直接进入主屏幕。"
                ))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
            )

            DisclosureGroup(tr("Setup log", "安装日志")) {
                engineLog
                    .frame(height: 150)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            HStack {
                Label(tr("Created", "创建成功"), systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 12))
                Spacer()
                Button(tr("Done", "完成")) { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func guideRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var engineLog: some View {
        VPhoneLogTextView(buffer: model.engine.log, channel: .console, revision: model.engine.log.revision, fontSize: 10)
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func stepIcon(_ status: VPhoneCreateEngine.StepStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    private var statusBadge: some View {
        Group {
            switch model.engine.status {
            case .running: Label("Running…", systemImage: "gearshape.2").foregroundStyle(.blue)
            case .done: Label("Created", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            case .failed: Label("Failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            case .cancelled: Label("Cancelled", systemImage: "stop.circle").foregroundStyle(.secondary)
            case .idle: EmptyView()
            }
        }
        .font(.system(size: 12))
    }
}
