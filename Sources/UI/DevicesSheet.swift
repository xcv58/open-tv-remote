import SwiftUI

struct DevicesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showingManual = false

    var body: some View {
        NavigationStack {
            List {
                if !model.devices.isEmpty {
                    Section("Your TVs") {
                        ForEach(model.devices) { device in
                            Button {
                                model.select(device)
                                dismiss()
                            } label: {
                                DeviceRow(name: device.name, brand: device.brand, host: device.host,
                                          isCurrent: device.id == model.currentID, isPaired: device.hasCredentials)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Forget", systemImage: "trash", role: .destructive) { model.forget(device) }
                            }
                            .swipeActions {
                                Button("Forget", systemImage: "trash", role: .destructive) { model.forget(device) }
                            }
                        }
                    }
                }

                if model.discovery.localNetworkDenied {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Local network access is off", systemImage: "wifi.exclamationmark")
                                .font(.headline)
                                .foregroundStyle(.orange)
                            Text("Remote Lab needs it to find and control TVs on your Wi-Fi. Turn on Local Network for Remote Lab in Settings → Privacy & Security → Local Network.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            #if os(iOS)
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .font(.footnote.weight(.semibold))
                            #endif
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    let saved = Set(model.devices.map(\.id))
                    let fresh = model.discovery.found.filter { !saved.contains($0.id) }
                    ForEach(fresh) { tv in
                        Button {
                            model.select(tv.device)
                            dismiss()
                        } label: {
                            DeviceRow(name: tv.name, brand: tv.brand, host: tv.host, isCurrent: false, isPaired: nil)
                        }
                        .buttonStyle(.plain)
                    }
                    if fresh.isEmpty && !model.discovery.isScanning {
                        Text(model.discovery.found.isEmpty
                             ? "No TVs found. Make sure your TV is on and connected to the same Wi-Fi, or add it by IP address."
                             : "No other TVs found.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button("Add by IP address…", systemImage: "plus") { showingManual = true }
                } header: {
                    HStack {
                        Text("On your network")
                        Spacer()
                        if model.discovery.isScanning {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            }
            .navigationTitle("TVs")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Scan again", systemImage: "arrow.clockwise") { model.discovery.start() }
                        .disabled(model.discovery.isScanning)
                }
            }
            .sheet(isPresented: $showingManual) {
                ManualAddSheet { device in
                    model.select(device)
                    dismiss()
                }
            }
        }
        .onAppear { model.discovery.start() }
        .onDisappear { model.discovery.stop() }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 520)
        #endif
    }
}

private struct DeviceRow: View {
    let name: String
    let brand: TVBrand
    let host: String
    let isCurrent: Bool
    let isPaired: Bool?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "tv")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isCurrent ? .black : Theme.label)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isCurrent ? Theme.accent : Color.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.semibold))
                Text("\(brand.shortName) · \(host)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isPaired == false {
                Text("Needs pairing").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
            }
            if isCurrent {
                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Theme.accent)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct ManualAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (TVDevice) -> Void

    @State private var brand: TVBrand = .androidTV
    @State private var host = ""
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $brand) {
                        ForEach(TVBrand.allCases) { Text($0.displayName).tag($0) }
                    }
                } footer: {
                    Text(brand.examples)
                }
                Section {
                    TextField("IP address (e.g. 192.168.1.42)", text: $host)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        .textInputAutocapitalization(.never)
                        #endif
                    TextField("Name (optional)", text: $name)
                } footer: {
                    Text("You can usually find the IP address in your TV's network settings.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add TV")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let trimmed = host.trimmingCharacters(in: .whitespaces)
                        let label = name.trimmingCharacters(in: .whitespaces)
                        onAdd(TVDevice(name: label.isEmpty ? "\(brand.shortName) TV" : label, brand: brand, host: trimmed))
                        dismiss()
                    }
                    .disabled(!LocalNetwork.isValidIPv4(host.trimmingCharacters(in: .whitespaces)))
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 320)
        #endif
    }
}
