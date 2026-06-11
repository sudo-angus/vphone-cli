import SwiftUI

struct VPhoneManagerView: View {
    @Bindable var model: VPhoneManagerModel

    @State private var confirmDelete: VPhoneManagedVM?
    @State private var showOptions = false
    @State private var createModel: VPhoneCreateModel?
    @State private var pane: DetailPane = .console

    private enum DetailPane: String, CaseIterable, Identifiable {
        case console = "Console"
        case network = "Network"
        var id: String { rawValue }
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 460)
            detail
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, minHeight: 520)
        .toolbar { toolbarContent }
        .alert(
            "Error",
            isPresented: .init(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
        ) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
        .alert(item: $model.restartPrompt) { prompt in
            Alert(
                title: Text(prompt.title),
                message: Text(prompt.message),
                primaryButton: .destructive(Text("Restart")) {
                    if let vm = model.vms.first(where: { $0.id == prompt.vmID }) {
                        Task { await model.restart(vm) }
                    }
                },
                secondaryButton: .cancel(Text("Ignore"))
            )
        }
        .alert(item: $confirmDelete) { vm in
            Alert(
                title: Text("Move “\(vm.displayName)” to Trash?"),
                message: Text("This deletes the entire VM directory (\(vm.displaySize)). This cannot be undone from the manager."),
                primaryButton: .destructive(Text("Move to Trash")) { model.moveToTrash(vm) },
                secondaryButton: .cancel()
            )
        }
        .sheet(isPresented: $showOptions) {
            if let vm = model.selectedVM {
                VPhoneOptionsSheet(vm: vm, model: model, isPresented: $showOptions)
            }
        }
        .sheet(item: $createModel) { cm in
            VPhoneCreateWizardView(model: cm, onDismiss: {
                createModel = nil
                model.refreshLibrary()
            })
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                ForEach(model.vms) { vm in
                    VMRow(vm: vm)
                        .tag(vm.id)
                        .contextMenu { rowContextMenu(vm) }
                }
            }
            .listStyle(.inset)

            Divider()
            adminBar
        }
    }

    private struct VMRow: View {
        let vm: VPhoneManagedVM

        var body: some View {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor(vm))
                    .frame(width: 9, height: 9)
                    .help(statusText(vm))
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.displayName)
                        .font(.system(.body, design: .default))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if vm.runState.isActive {
                    Text(statusText(vm))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(statusColor(vm))
                }
            }
            .padding(.vertical, 3)
        }

        private var subtitle: String {
            var parts = [vm.variant]
            if let ios = vm.iosVersion { parts.append(ios) }
            parts.append(vm.displaySize)
            return parts.joined(separator: " · ")
        }
    }

    private var adminBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.amfidontRunning ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(model.amfidontRunning ? "AMFI bypass active" : "AMFI bypass off")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            if model.authStatus == .authorized {
                Button("Remove…") { Task { await model.deauthorize() } }
                    .controlSize(.small)
                    .help("Remove /etc/sudoers.d/vphone")
            } else {
                Button("Authorize admin") { Task { await model.authorize() } }
                    .controlSize(.small)
                    .help("Install a scoped sudoers rule so amfidont and the TCP workaround run without a password")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.bar)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let vm = model.selectedVM {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(vm)
                Divider()
                paneSwitcher(vm)
                Divider()
                switch pane {
                case .console: ConsoleLogPane(buffer: vm.log)
                case .network: networkPane(vm)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text(model.vms.isEmpty ? "No VMs found" : "Select a VM")
                    .foregroundStyle(.secondary)
                if model.vms.isEmpty {
                    Text("Create one with the firmware pipeline, then it appears here.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHeader(_ vm: VPhoneManagedVM) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(statusColor(vm)).frame(width: 11, height: 11)
                Text(vm.displayName).font(.title3.weight(.semibold))
                Text(statusText(vm))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(statusColor(vm))
                Spacer()
            }

            HStack(spacing: 18) {
                infoChip("Hardware", vm.hardwareSummary)
                infoChip("Variant", vm.variant)
                infoChip("Size", vm.displaySize)
                infoChip("Identity", vm.provisioned ? "Provisioned" : "Unprovisioned")
            }

            if vm.runState.isActive {
                HStack(spacing: 18) {
                    if let ssh = vm.sshPort { infoChip("SSH", "127.0.0.1:\(ssh)") }
                    if let rpc = vm.rpcPort { infoChip("RPC", "127.0.0.1:\(rpc)") }
                    infoChip("TCP workaround", vm.usingTCPWorkaround ? "on" : "off")
                    if vm.adopted { infoChip("Source", "adopted") }
                }
            }

            HStack(spacing: 8) {
                if vm.runState.isActive {
                    IconButton(systemImage: "stop.fill", help: "Stop the VM", tint: .red) {
                        Task { await model.stop(vm) }
                    }
                    IconButton(systemImage: "arrow.clockwise", help: "Restart the VM") {
                        Task { await model.restart(vm) }
                    }
                } else {
                    Button { Task { await model.start(vm) } } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
                IconButton(systemImage: "slider.horizontal.3", help: "Options…") {
                    showOptions = true
                }
            }
        }
        .padding(14)
    }

    /// Icon-only action button with an explicit resting affordance: `.bordered`
    /// buttons truncate labels in a tight header row and give no hover cue, so
    /// this draws its own fill/border and brightens under the pointer.
    private struct IconButton: View {
        let systemImage: String
        let help: String
        var tint: Color = .primary
        var disabled = false
        let action: () -> Void

        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(disabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint))
                    .frame(width: 32, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.primary.opacity(hovering && !disabled ? 0.12 : 0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.primary.opacity(hovering && !disabled ? 0.28 : 0.14), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .onHover { hovering = $0 }
            .help(help)
        }
    }

    private func infoChip(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    // MARK: - Log pane

    /// The console/network panes read `buffer.revision` to drive incremental
    /// text updates. That read MUST happen inside a dedicated leaf view's body,
    /// not in `VPhoneManagerView`'s — otherwise every boot-time log chunk (which
    /// bumps `revision`) invalidates the whole window (sidebar list, header,
    /// network rows), and the early-boot output burst beachballs the UI.
    private struct ConsoleLogPane: View {
        let buffer: VPhoneLogBuffer
        var body: some View {
            VPhoneLogTextView(buffer: buffer, channel: .console, revision: buffer.revision)
        }
    }

    private struct NetworkLogPane: View {
        let buffer: VPhoneLogBuffer
        var body: some View {
            VPhoneLogTextView(buffer: buffer, channel: .network, revision: buffer.revision)
                .overlay(alignment: .topLeading) {
                    if buffer.networkTotal == 0 {
                        Text("(no networking log lines yet)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    // MARK: - Pane switcher + network

    private func paneSwitcher(_ vm: VPhoneManagedVM) -> some View {
        HStack {
            Picker("", selection: $pane) {
                ForEach(DetailPane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            Spacer()
            switch pane {
            case .console:
                Button { model.exportConsoleLog(vm) } label: {
                    Label("Export Console Log…", systemImage: "square.and.arrow.up")
                }
                .controlSize(.small)
            case .network:
                Button { model.exportNetworkLog(vm) } label: {
                    Label("Export Network Log…", systemImage: "square.and.arrow.up")
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private struct NetStatus {
        let color: Color
        let text: String
    }

    private func networkPane(_ vm: VPhoneManagedVM) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                netRow("TCP workaround", tcpStatus(vm))
                netRow("SOCKS5 proxy", socks5Status(vm))
                netRow("SSH forward", forwardStatus(port: vm.sshPort, listening: vm.network.sshListening, guestPort: 22222, active: vm.runState.isActive))
                netRow("RPC forward", forwardStatus(port: vm.rpcPort, listening: vm.network.rpcListening, guestPort: 5910, active: vm.runState.isActive))
            }
            .padding(.vertical, 4)
            Divider()
            HStack {
                Text("NETWORK LOG")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                if let ts = vm.network.checkedAt, vm.runState.isActive {
                    Text("checked \(ts.formatted(date: .omitted, time: .standard))")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
            NetworkLogPane(buffer: vm.log)
        }
    }

    private func netRow(_ label: String, _ status: NetStatus) -> some View {
        HStack(spacing: 10) {
            Circle().fill(status.color).frame(width: 9, height: 9)
            Text(label)
                .font(.system(size: 12))
                .frame(width: 130, alignment: .leading)
            Text(status.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    private func tcpStatus(_ vm: VPhoneManagedVM) -> NetStatus {
        guard vm.runState.isActive else { return NetStatus(color: .gray, text: "off") }
        if !vm.enableTCPWorkaround { return NetStatus(color: .gray, text: "disabled") }
        if !vm.usingTCPWorkaround { return NetStatus(color: .gray, text: "off (held by another VM)") }
        return vm.network.tcpWorkaroundActive
            ? NetStatus(color: .green, text: "active · relay up")
            : NetStatus(color: .orange, text: "starting / relay down")
    }

    private func socks5Status(_ vm: VPhoneManagedVM) -> NetStatus {
        guard vm.socks5Port > 0 else { return NetStatus(color: .gray, text: "off") }
        guard vm.runState.isActive else { return NetStatus(color: .gray, text: "off") }
        return vm.network.socks5Listening == true
            ? NetStatus(color: .green, text: "127.0.0.1:\(vm.socks5Port)")
            : NetStatus(color: .orange, text: "starting (:\(vm.socks5Port))")
    }

    private func forwardStatus(port: Int?, listening: Bool, guestPort: Int, active: Bool) -> NetStatus {
        guard active else { return NetStatus(color: .gray, text: "off") }
        guard let port else { return NetStatus(color: .gray, text: "n/a (adopted)") }
        return listening
            ? NetStatus(color: .green, text: "127.0.0.1:\(port) → guest:\(guestPort)")
            : NetStatus(color: .orange, text: "starting (:\(port))")
    }

    // MARK: - Menus / toolbar

    @ViewBuilder
    private func rowContextMenu(_ vm: VPhoneManagedVM) -> some View {
        if vm.runState.isActive {
            Button("Stop") { Task { await model.stop(vm) } }
            Button("Restart") { Task { await model.restart(vm) } }
        } else {
            Button("Start") { Task { await model.start(vm) } }
        }
        Divider()
        Button("Export Log Bundle (zip)…") { model.exportLogs(vm) }
        Button("Reveal in Finder") { model.revealInFinder(vm) }
        Divider()
        Button("Move to Trash…") { confirmDelete = vm }
            .disabled(vm.runState.isActive)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Button { model.refreshLibrary() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
        }
        ToolbarItem {
            Button {
                createModel = VPhoneCreateModel(registry: model.registry, privilege: model.privilege)
            } label: {
                Label("New VM…", systemImage: "plus")
            }
            .help("Create a new vPhone in vms/ (firmware download → restore → CFW).")
        }
    }
}

// MARK: - Status mapping (shared)

@MainActor
private func statusColor(_ vm: VPhoneManagedVM) -> Color {
    switch vm.runState {
    case .stopped: .gray
    case .starting, .stopping: .blue
    case .running:
        switch vm.health {
        case .guestDisconnected: .orange
        default: .green
        }
    case .unresponsive: .red
    case .failed: .red
    }
}

@MainActor
private func statusText(_ vm: VPhoneManagedVM) -> String {
    switch vm.runState {
    case .stopped: vm.lastExitCode != nil ? "Stopped" : "Idle"
    case .starting: "Starting…"
    case .stopping: "Stopping…"
    case .running:
        switch vm.health {
        case .guestDisconnected: "Guest disconnected"
        case .starting: "Connecting…"
        default: "Running"
        }
    case .unresponsive: "Unresponsive"
    case .failed: "Failed"
    }
}
