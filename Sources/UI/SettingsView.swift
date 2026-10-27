import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showingDevices = false

    private var openSourceLicense: String {
        guard let url = Bundle.main.url(forResource: "OpenRemote-LICENSE", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "The MIT License is also available in the source repository’s LICENSE file."
        }
        return text
    }

    private var privacyPolicy: String {
        guard let url = Bundle.main.url(forResource: "RemoteLab-Privacy", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "The privacy policy is unavailable. Please contact the developer through TestFlight feedback."
        }
        return text
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("TV") {
                    Button {
                        showingDevices = true
                    } label: {
                        LabeledContent(model.current?.name ?? "No TV chosen", value: model.current.map { $0.brand.shortName } ?? "Choose…")
                    }
                    .buttonStyle(.plain)
                }

                #if os(iOS)
                Section {
                    Toggle("Show remote automatically", isOn: Binding {
                        model.remoteActivity.options.automatic
                    } set: {
                        model.remoteActivity.setAutomatic($0, device: model.current)
                    })
                } header: {
                    Text("Dynamic Island and Lock Screen")
                } footer: {
                    Text("Show a shortcut for your selected TV. After dismissing it, select a TV or turn this setting off and on to show it again.")
                }
                #endif

                JellyfinSettingsSection()

                if model.jellyfin.isReady && !model.jellyfin.pins.isEmpty {
                    Section {
                        ForEach(model.jellyfin.pins) { pin in
                            Label(pin.name, systemImage: pin.type == "Series" ? "tv" : pin.type == "Movie" ? "film" : "folder")
                        }
                        .onMove { model.jellyfin.movePins(from: $0, to: $1) }
                        .onDelete { model.jellyfin.removePins(at: $0) }
                    } header: {
                        Text("Pinned")
                    } footer: {
                        Text("Pin shows, movies and libraries from the Watch page: long-press one and choose Pin.")
                    }
                }

                if model.current != nil {
                    Section {
                        ForEach(model.allApps, id: \.app.id) { entry in
                            Toggle(entry.app.name, isOn: Binding {
                                model.isShown(entry.app)
                            } set: {
                                model.setShown(entry.app, $0)
                            })
                        }
                    } header: {
                        Text("Apps on the Watch page")
                    } footer: {
                        Text(model.installedApps == nil
                             ? "Your TV doesn't share its app list, so these are popular apps."
                             : "These are the apps installed on your TV.")
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Free and open source", systemImage: "heart.fill")
                            .font(.headline)
                            .foregroundStyle(Theme.accent)
                        Text("Remote Lab is an independent fork of Open TV Remote by Nathan Butler, released under the MIT License. No ads, analytics or tracking. TV commands stay on your local network; saved TV details and interface preferences can sync through your iCloud account. TV pairing credentials are excluded from settings sync. Optional Jellyfin sign-in tokens can sync through iCloud Keychain.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Link("View the fork on GitHub", destination: URL(string: "https://github.com/xcv58/open-tv-remote")!)
                            .font(.footnote.weight(.semibold))
                        Link("Original project by Nathan Butler", destination: URL(string: "https://github.com/iamnbutler/open-tv-remote")!)
                            .font(.footnote)
                        NavigationLink("Privacy policy") {
                            ScrollView {
                                Text(privacyPolicy)
                                    .font(.body)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding()
                            }
                            .navigationTitle("Privacy")
                        }
                        .font(.footnote)
                        NavigationLink("Open-source license") {
                            ScrollView {
                                Text(openSourceLicense)
                                    .font(.footnote.monospaced())
                                    .textSelection(.enabled)
                                    .padding()
                            }
                            .navigationTitle("MIT License")
                        }
                        .font(.footnote)
                    }
                    .padding(.vertical, 4)
                }

                Section("App icons") {
                    HStack {
                        Link("Adapted from selfh.st", destination: URL(string: "https://selfh.st/icons/")!)
                        Spacer()
                        Link("CC BY 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                    }
                    HStack {
                        Link("Dashboard Icons", destination: URL(string: "https://dashboardicons.com/")!)
                        Spacer()
                        Link("Apache 2.0", destination: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!)
                    }
                    HStack {
                        Link("Simple Icons", destination: URL(string: "https://simpleicons.org/")!)
                        Spacer()
                        Link("CC0", destination: URL(string: "https://creativecommons.org/publicdomain/zero/1.0/")!)
                    }
                }
                .font(.footnote)
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if model.jellyfin.isReady && !model.jellyfin.pins.isEmpty {
                    ToolbarItem(placement: .topBarLeading) { EditButton() }
                }
            }
            #endif
            .sheet(isPresented: $showingDevices) { DevicesSheet() }
        }
        #if os(macOS)
        .frame(width: 460, height: 620)
        #endif
    }
}

/// Opens settings: the Settings window on the Mac, a sheet elsewhere.
struct SettingsButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        #if os(macOS)
        SettingsLink { icon }
            .buttonStyle(.plain)
        #else
        Button { model.showingSettings = true } label: { icon }
            .buttonStyle(.plain)
        #endif
    }

    private var icon: some View {
        Image(systemName: "gearshape.fill")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Theme.label)
            .frame(width: 44, height: 44)
            .background(KeySurface(shape: Circle()))
            .accessibilityLabel("Settings")
    }
}
