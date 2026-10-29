import SwiftUI

@main
struct OpenRemoteApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        #if os(macOS)
        .defaultSize(width: 420, height: 900)
        .windowResizability(.contentMinSize)
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        #endif
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Pager()
                .toolbar(.hidden)
                .jellyfinDestinations()
        }
            .safeAreaInset(edge: .bottom) { JellyfinStatusBar() }
            #if os(iOS)
            .background {
                VolumeButtons(isEnabled: scenePhase == .active && model.current != nil) { model.press($0) }
                    .frame(width: 1, height: 1)
            }
            #endif
            #if os(macOS)
            .frame(minWidth: 380, minHeight: 760)
            #endif
            .sheet(isPresented: $model.showingDevices, onDismiss: model.presentPendingRemoteShortcut) { DevicesSheet() }
            .sheet(isPresented: $model.showingKeyboard, onDismiss: model.presentPendingRemoteShortcut) { KeyboardSheet() }
            .sheet(isPresented: $model.showingApps, onDismiss: model.presentPendingRemoteShortcut) { AppsSheet() }
            #if os(iOS)
            .sheet(isPresented: $model.showingSettings, onDismiss: model.presentPendingRemoteShortcut) { SettingsView() }
            .fullScreenCover(item: $model.remoteControlMode) { mode in
                switch mode {
                case .eyesFree: JoystickScreen()
                case .cursor: CursorScreen()
                }
            }
            .onOpenURL { model.handleRemoteShortcut($0) }
            #else
            .sheet(item: $model.remoteControlMode) { mode in
                switch mode {
                case .eyesFree: JoystickScreen()
                case .cursor: CursorScreen()
                }
            }
            #endif
            .sheet(isPresented: pairingPresented) { PairingSheet() }
            .animation(.snappy, value: model.state)
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: model.sceneDidBecomeActive()
                case .background: model.sceneDidEnterBackground()
                default: break
                }
            }
            .task {
                if scenePhase == .active { model.sceneDidBecomeActive() }
                if model.devices.isEmpty { model.showingDevices = true }
            }
    }

    private var pairingPresented: Binding<Bool> {
        Binding {
            if case .pairing = model.state { return true }
            return false
        } set: { presented in
            if !presented, case .pairing = model.state { model.cancelPairing() }
        }
    }
}

/// The remote and the Watch page side by side; swipe (or use the switcher) to move between them.
private struct Pager: View {
    @AppStorage("page") private var stored = 0
    @State private var page: Int? = 0

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                RemoteScreen()
                    .containerRelativeFrame(.horizontal)
                    .id(0)
                WatchScreen()
                    .containerRelativeFrame(.horizontal)
                    .id(1)
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $page)
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PageSwitcher(page: Binding { page ?? 0 } set: { new in withAnimation(.snappy) { page = new } })
        }
        .background(Theme.background.ignoresSafeArea())
        .onAppear { page = stored }
        .onChange(of: stored) { _, new in if page != new { page = new } }
        .onChange(of: page) { _, new in if let new { stored = new } }
    }
}

struct PageSwitcher: View {
    static let height: CGFloat = 44
    @Binding var page: Int

    var body: some View {
        HStack(spacing: 4) {
            tab("Remote", systemImage: "av.remote", index: 0, key: "1")
            tab("Watch", systemImage: "play.rectangle.on.rectangle", index: 1, key: "2")
        }
        .padding(4)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }

    private func tab(_ title: String, systemImage: String, index: Int, key: KeyEquivalent) -> some View {
        Button {
            Haptics.tick()
            page = index
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(page == index ? Color.black : Theme.secondary)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Capsule().fill(page == index ? Theme.accent : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: .command)
        .accessibilityAddTraits(page == index ? .isSelected : [])
    }
}
