import SwiftUI

struct LGWakeSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""

    var body: some View {
        if let device = model.current, device.brand == .lg {
            Section {
                TextField("MAC address (AA:BB:CC:DD:EE:FF)", text: $address)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    .keyboardType(.asciiCapable)
                    #endif
                    .accessibilityLabel("TV network MAC address")
                if !address.isEmpty && WakeOnLAN.normalizedMAC(address) == nil {
                    Text("Enter six pairs of hexadecimal digits, separated by colons or hyphens.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Button("Save MAC address") {
                    if model.saveWakeAddress(address, for: device.id) { address = model.current?.macAddress ?? address }
                }
                .disabled(WakeOnLAN.normalizedMAC(address) == nil || WakeOnLAN.normalizedMAC(address) == device.macAddress || model.isWakingTV)
                if device.macAddress != nil, WakeOnLAN.normalizedMAC(address) == device.macAddress {
                    Label("Address saved", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                if model.isWakingTV {
                    HStack { ProgressView(); Text("Waking TV…") }
                    Button("Cancel wake") { model.cancelWakeTV() }
                } else {
                    Button("Wake TV", systemImage: "power") { model.wakeTV() }
                        .disabled(!device.hasCredentials || device.macAddress == nil || model.state == .connected)
                }
            } header: {
                Text("Wake-on-LAN")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enable TV On With Mobile → Turn on via Wi-Fi on your LG TV. Names vary by model. The TV must have standby power and be on the same local network.")
                    Text("Open Remote learns the address when the TV shares it. Otherwise, enter the MAC address shown in the TV's network settings for its current Wi-Fi or Ethernet connection. Update it if you change connections.")
                    Text("Pair while the TV is on first. Enabling network standby can increase standby power use. Some models only wake over Ethernet.")
                }
            }
            .onAppear { address = device.macAddress ?? "" }
            .onChange(of: device.id) { _, _ in address = device.macAddress ?? "" }
            .onChange(of: device.macAddress) { old, new in
                if address.isEmpty || WakeOnLAN.normalizedMAC(address) == old { address = new ?? "" }
            }
        }
    }
}
