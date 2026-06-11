import SwiftUI

/// Per-VM boot options editor — the GUI replacement for hand-editing `boot.sh`
/// flags. Drafts into local state so Cancel discards; Save writes back to the
/// VM and persists `vphone-meta.json`. Changes take effect on the next start.
struct VPhoneOptionsSheet: View {
    let vm: VPhoneManagedVM
    let model: VPhoneManagerModel
    @Binding var isPresented: Bool

    @State private var displayName: String
    @State private var iosVersion: String
    @State private var softwareKeyboard: Bool
    @State private var tcpWorkaround: Bool
    @State private var socks5Enabled: Bool
    @State private var socks5Port: String
    @State private var sshPort: String
    @State private var rpcPort: String
    @State private var extraFlags: String

    init(vm: VPhoneManagedVM, model: VPhoneManagerModel, isPresented: Binding<Bool>) {
        self.vm = vm
        self.model = model
        _isPresented = isPresented
        _displayName = State(initialValue: vm.displayName)
        _iosVersion = State(initialValue: vm.iosVersion ?? "")
        _softwareKeyboard = State(initialValue: vm.softwareKeyboard)
        _tcpWorkaround = State(initialValue: vm.enableTCPWorkaround)
        _socks5Enabled = State(initialValue: vm.socks5Port > 0)
        _socks5Port = State(initialValue: vm.socks5Port > 0 ? String(vm.socks5Port) : "")
        _sshPort = State(initialValue: vm.sshForwardPref.map(String.init) ?? "")
        _rpcPort = State(initialValue: vm.rpcForwardPref.map(String.init) ?? "")
        _extraFlags = State(initialValue: vm.bootFlags.joined(separator: " "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Options — \(vm.displayName)").font(.headline)

            Form {
                Section {
                    TextField("Display name", text: $displayName)
                    TextField("iOS version", text: $iosVersion, prompt: Text("optional"))
                } header: {
                    Text("Identity")
                } footer: {
                    Text("iOS version is a display-only note shown in the VM list; it does not affect boot.")
                }
                Section("Input") {
                    Toggle("Software keyboard (drop USB keyboard)", isOn: $softwareKeyboard)
                }
                Section {
                    Toggle("TCP workaround (host proxy for VPN-broken NAT)", isOn: $tcpWorkaround)
                    Toggle("SOCKS5 proxy into guest network", isOn: $socks5Enabled)
                    if socks5Enabled {
                        TextField("SOCKS5 port", text: $socks5Port, prompt: Text("1080"))
                    }
                    TextField("SSH forward port", text: $sshPort, prompt: Text("auto"))
                    TextField("RPC forward port", text: $rpcPort, prompt: Text("auto"))
                } header: {
                    Text("Networking")
                } footer: {
                    Text("Leave forward ports empty to pick a free port automatically on each start.")
                }
                Section("Advanced") {
                    TextField("Extra boot flags", text: $extraFlags, prompt: Text("e.g. --kernel-debug-port 6000"))
                }
            }
            .formStyle(.grouped)

            if vm.runState.isActive {
                Label("Changes apply on next start/restart.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func save() {
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
        if !trimmedName.isEmpty { vm.displayName = trimmedName }
        let trimmedIOS = iosVersion.trimmingCharacters(in: .whitespaces)
        vm.iosVersion = trimmedIOS.isEmpty ? nil : trimmedIOS
        vm.softwareKeyboard = softwareKeyboard
        vm.enableTCPWorkaround = tcpWorkaround
        // Toggle off means off regardless of what's left in the port field;
        // toggle on with an empty/garbage field falls back to the 1080 default.
        vm.socks5Port = socks5Enabled ? (Int(socks5Port.trimmingCharacters(in: .whitespaces)) ?? 1080) : 0
        vm.sshForwardPref = Int(sshPort.trimmingCharacters(in: .whitespaces))
        vm.rpcForwardPref = Int(rpcPort.trimmingCharacters(in: .whitespaces))
        vm.bootFlags = extraFlags.split(separator: " ").map(String.init)
        model.saveOptions(for: vm)
        isPresented = false
    }
}
