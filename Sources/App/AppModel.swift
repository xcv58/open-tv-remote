import Foundation
import Observation

@MainActor
@Observable
final class AppModel: TVDriverDelegate {
    private(set) var devices: [TVDevice] = DeviceStore.load()
    private(set) var currentID: String? = DeviceStore.currentID
    private(set) var state: ConnectionState = .idle
    private(set) var installedApps: [TVApp]?
    /// True while we search the network for a saved TV that stopped answering at its old address.
    private(set) var isRelocating = false

    var showingDevices = false
    var showingKeyboard = false
    var showingApps = false
    var showingSettings = false
    var showingJoystick = false {
        didSet {
            #if os(iOS)
            #if DEBUG
            if DemoMode.isEnabled { return }
            #endif
            // Persist the chosen view only. Gesture state and queued input stay ephemeral.
            UserDefaults.standard.set(showingJoystick, forKey: "remoteView.eyesFree.v1")
            #endif
        }
    }
    #if os(iOS)
    let remoteActivity = AppModel.makeRemoteActivityController()
    private var pendingRemoteShortcut: URL?
    @ObservationIgnored private var isForeground = false

    private static func makeRemoteActivityController() -> RemoteActivityController {
        #if DEBUG
        if DemoMode.isEnabled {
            return RemoteActivityController(system: ActivityKitRemoteActivitySystem(allowsSystemAccess: false),
                                            load: { nil }, save: { _ in },
                                            loadOptions: { RemoteActivityOptions(automatic: false) }, saveOptions: { _ in })
        }
        #endif
        return RemoteActivityController(system: ActivityKitRemoteActivitySystem())
    }
    #endif

    let discovery = Discovery()
    let jellyfin = JellyfinStore()

    @ObservationIgnored private var driver: TVDriver?
    @ObservationIgnored private var relocateTask: Task<Void, Never>?
    @ObservationIgnored private var relocationAttempted = false

    var current: TVDevice? { devices.first { $0.id == currentID } }

    init() {
        #if DEBUG
        if DemoMode.isEnabled {
            devices = DemoMode.devices
            currentID = DemoMode.devices[0].id
            let driver = DemoDriver(device: DemoMode.devices[0])
            driver.delegate = self
            self.driver = driver
            state = .connected
            switch DemoMode.sheet {
            case "apps": showingApps = true
            case "devices": showingDevices = true
            case "keyboard": showingKeyboard = true
            case "settings": showingSettings = true
            default: break
            }
            return
        }
        #endif
        #if os(iOS)
        NotificationCenter.default.addObserver(forName: RemoteActivityPersistence.actionNotification, object: nil, queue: .main) { [weak self] note in
            guard let event = note.object as? RemoteActivityActionEvent else { return }
            MainActor.assumeIsolated { self?.handleRemoteActivityAction(event) }
        }
        remoteActivity.reconcile(selectedID: currentID)
        if current != nil, !isConnectionPaused {
            showingJoystick = UserDefaults.standard.bool(forKey: "remoteView.eyesFree.v1")
        }
        #endif
        NotificationCenter.default.addObserver(forName: CloudSettings.didChange, object: nil, queue: .main) { [weak self] note in
            let keys = note.userInfo?["keys"] as? [String] ?? []
            MainActor.assumeIsolated { self?.settingsChanged(keys) }
        }
        CloudSettings.start()
        if let current {
            activate(current)
        }
    }

    // MARK: Sync

    private func settingsChanged(_ keys: [String]) {
        if keys.contains(CloudSettings.devices) { adoptSharedDevices() }
        if keys.contains(CloudSettings.appChoices) { appChoices = Self.loadAppChoices() }
        jellyfin.settingsChanged(keys)
    }

    /// Takes the TV list from the user's other devices, keeping this device's pairing for each TV.
    /// A TV that moved to a new address elsewhere is matched by name, so it stays paired here.
    private func adoptSharedDevices() {
        guard let shared = DeviceStore.loadShared() else { return }
        let mine = devices
        let previous = current
        devices = shared.map { tv in
            guard let local = mine.first(where: { $0.id == tv.id })
                ?? mine.first(where: { $0.brand == tv.brand && $0.name == tv.name }) else { return tv }
            var tv = tv
            tv.token = local.token
            tv.isPaired = local.isPaired
            tv.macAddress = tv.macAddress ?? local.macAddress
            return tv
        }
        DeviceStore.save(devices)
        guard let previous, current == nil else { return }
        if let moved = devices.first(where: { $0.brand == previous.brand && $0.name == previous.name }) {
            activate(moved)
        } else {
            forget(previous)
        }
    }

    // MARK: Devices

    func select(_ device: TVDevice) {
        #if os(iOS)
        remoteActivity.resume(device.id)
        #endif
        if !devices.contains(where: { $0.id == device.id }) {
            devices.append(device)
            DeviceStore.save(devices)
        }
        activate(devices.first { $0.id == device.id } ?? device)
    }

    func forget(_ device: TVDevice) {
        devices.removeAll { $0.id == device.id }
        DeviceStore.save(devices)
        if device.id == currentID {
            driver?.disconnect()
            driver = nil
            currentID = nil
            #if os(iOS)
            remoteActivity.selectionChanged(to: nil)
            #endif
            DeviceStore.currentID = nil
            state = .idle
            installedApps = nil
        }
    }

    private func activate(_ device: TVDevice) {
        driver?.disconnect()
        relocateTask?.cancel()
        relocateTask = nil
        isRelocating = false
        relocationAttempted = false
        currentID = device.id
        #if os(iOS)
        remoteActivity.selectionChanged(to: device.id)
        #endif
        DeviceStore.currentID = device.id
        installedApps = nil
        let driver = Self.makeDriver(device)
        driver.delegate = self
        self.driver = driver
        state = driver.state
        #if os(iOS)
        if isForeground && !isConnectionPaused {
            driver.connect()
            remoteActivity.ensureAutomatic(current)
        }
        #else
        driver.connect()
        #endif
    }

    private static func makeDriver(_ device: TVDevice) -> TVDriver {
        switch device.brand {
        case .androidTV: AndroidTVDriver(device: device)
        case .roku: RokuDriver(device: device)
        case .samsung: SamsungDriver(device: device)
        case .lg: LGDriver(device: device)
        }
    }

    // MARK: Connection

    var isConnectionPaused: Bool {
        #if os(iOS)
        return currentID != nil && remoteActivity.options.disconnectedDeviceID == currentID
        #else
        return false
        #endif
    }

    func reconnect(explicit: Bool = true) {
        guard let driver else { return }
        #if os(iOS)
        if explicit, let currentID { remoteActivity.resume(currentID) }
        guard !isConnectionPaused else { return }
        #endif
        switch state {
        case .connected, .connecting, .pairing: return
        default:
            relocationAttempted = false
            driver.connect()
        }
        #if os(iOS)
        if isForeground { remoteActivity.ensureAutomatic(current) }
        #endif
    }

    /// iOS kills sockets in the background without telling us, so the first press after
    /// returning would go into a dead connection. Drop it ourselves and reconnect on return.
    func sceneDidEnterBackground() {
        #if os(iOS)
        isForeground = false
        remoteActivity.sceneDidEnterBackground()
        #endif
        if case .pairing = state { return }
        driver?.disconnect()
    }

    func sceneDidBecomeActive() {
        #if os(iOS)
        isForeground = true
        remoteActivity.reconcile(selectedID: currentID)
        remoteActivity.ensureAutomatic(current)
        #endif
        reconnect(explicit: false)
    }

    #if os(iOS)
    private func handleRemoteActivityAction(_ event: RemoteActivityActionEvent) {
        guard event.deviceID == currentID else { return }
        remoteActivity.reloadOptions()
        if event.action == .disconnect { disconnectRemoteSession() }
        else { remoteActivity.dismiss() }
    }

    func disconnectRemoteSession() {
        guard let currentID else { return }
        remoteActivity.pauseConnection(currentID)
        relocateTask?.cancel()
        relocateTask = nil
        isRelocating = false
        discovery.stop()
        showingJoystick = false
        driver?.disconnect()
        state = .idle
    }

    func handleRemoteShortcut(_ url: URL) {
        guard remoteActivity.accepts(url, selectedID: currentID) else { return }
        // Pairing is an explicit flow and must not be hidden by an external link.
        if case .pairing = state { return }
        pendingRemoteShortcut = nil
        // The main Island tap resumes the existing page, mode and any open sheet.
        guard RemoteActivityLink.opensEyesFree(url) else {
            remoteActivity.noteInteraction()
            return
        }
        pendingRemoteShortcut = url
        let dismissing = showingDevices || showingKeyboard || showingApps || showingSettings
        showingDevices = false
        showingKeyboard = false
        showingApps = false
        showingSettings = false
        if !dismissing { presentPendingRemoteShortcut() }
    }
    #endif

    func presentPendingRemoteShortcut() {
        #if os(iOS)
        guard let url = pendingRemoteShortcut,
              !showingDevices, !showingKeyboard, !showingApps, !showingSettings else { return }
        pendingRemoteShortcut = nil
        guard remoteActivity.accepts(url, selectedID: currentID) else { return }
        if case .pairing = state { return }
        remoteActivity.noteInteraction()
        UserDefaults.standard.set(0, forKey: "page")
        showingJoystick = true
        #endif
    }

    /// Routers hand out new addresses. If a saved TV stops answering, look for one with the same
    /// brand and name elsewhere on the network and move it there. Pairing survives the move.
    private func relocate(_ device: TVDevice) {
        guard relocateTask == nil, !relocationAttempted else { return }
        relocationAttempted = true
        isRelocating = true
        relocateTask = Task {
            defer {
                isRelocating = false
                relocateTask = nil
            }
            if !discovery.isScanning { discovery.start() }
            for _ in 0..<20 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, currentID == device.id else { return }
                if let match = discovery.found.first(where: {
                    $0.brand == device.brand && $0.name == device.name && $0.host != device.host
                }) {
                    move(device, to: match.host)
                    return
                }
                if !discovery.isScanning { return }
            }
        }
    }

    private func move(_ device: TVDevice, to host: String) {
        var moved = device
        moved.host = host
        devices.removeAll { $0.id == moved.id }
        if let i = devices.firstIndex(where: { $0.id == device.id }) {
            devices[i] = moved
        } else {
            devices.append(moved)
        }
        DeviceStore.save(devices)
        activate(moved)
    }

    /// Explicit user action — this is the only path that puts something on the TV screen.
    func startPairing() {
        #if os(iOS)
        if let currentID { remoteActivity.resume(currentID) }
        #endif
        driver?.pair()
    }

    func submitPairingCode(_ code: String) { driver?.submitPairingCode(code) }

    func cancelPairing() {
        driver?.disconnect()
        driver?.connect()
    }

    // MARK: Commands

    #if DEBUG
    private(set) var demoInputCount = 0
    private(set) var demoLastInput = "None"
    #endif

    func press(_ key: RemoteKey) {
        if isConnectionPaused { reconnect() }
        #if os(iOS)
        remoteActivity.noteInteraction()
        #endif
        driver?.send(key)
    }

    func pressInteractively(_ key: RemoteKey, request: RemoteInputRequest) async {
        guard state == .connected, !request.isCancelled, !Task.isCancelled else { return }
        #if os(iOS)
        remoteActivity.noteInteraction()
        #endif
        #if DEBUG
        if DemoMode.isEnabled {
            demoInputCount += 1
            demoLastInput = key.accessibilityName
        }
        #endif
        await driver?.sendInteractive(key, request: request)
    }

    func supports(_ key: RemoteKey) -> Bool { driver?.supports(key) ?? true }

    func sendText(_ text: String) {
        if isConnectionPaused { reconnect() }
        #if os(iOS)
        remoteActivity.noteInteraction()
        #endif
        driver?.sendText(text)
    }

    // MARK: Keyboard pad

    /// What's been typed on the keyboard pad since the last Return, for clear and for TVs that don't type live.
    var typed = ""

    var typesLive: Bool { driver?.typesLive ?? true }

    /// Each character goes to the TV as it's typed, where the TV appends what it's sent.
    func type(_ text: String) {
        typed += text
        if typesLive { sendText(text) }
    }

    func typeDelete() {
        if !typed.isEmpty { typed.removeLast() }
        if typesLive { press(.backspace) }
    }

    /// Deletes what's been typed since the last Return.
    func typeClear() {
        if typesLive {
            for _ in typed { press(.backspace) }
        }
        typed = ""
    }

    func typeReturn() {
        if typesLive {
            press(.enter)
        } else if !typed.isEmpty {
            sendText(typed)
        }
        typed = ""
    }

    /// Returns false when there's no paired TV to send it to.
    @discardableResult
    func launch(_ app: TVApp) -> Bool {
        guard let driver, current?.hasCredentials == true else { return false }
        if isConnectionPaused { reconnect() }
        #if os(iOS)
        remoteActivity.noteInteraction()
        #endif
        driver.launch(app)
        return true
    }

    var allApps: [(app: TVApp, style: CatalogApp?)] {
        guard let brand = current?.brand else { return [] }
        if let installedApps, !installedApps.isEmpty {
            return installedApps.map { ($0, CatalogApp.match(name: $0.name)) }
        }
        return CatalogApp.all.compactMap { c in c.tvApp(for: brand).map { ($0, Optional(c)) } }
    }

    // MARK: Watch page apps

    private static let defaultAppIDs: Set<String> = ["youtube", "netflix", "prime", "disney", "appletv", "jellyfin"]

    /// Explicit choices only; missing entries follow the defaults without writing them to storage.
    private var appChoices: [String: Bool] = loadAppChoices() {
        didSet { CloudSettings.set(appChoices, forKey: CloudSettings.appChoices) }
    }

    private static func loadAppChoices() -> [String: Bool] {
        UserDefaults.standard.dictionary(forKey: CloudSettings.appChoices) as? [String: Bool] ?? [:]
    }

    func isShown(_ app: TVApp) -> Bool {
        if let choice = appChoices[app.name.lowercased()] { return choice }
        guard let brand = current?.brand else { return false }
        return CatalogApp.all.contains { catalog in
            Self.defaultAppIDs.contains(catalog.id)
                && (catalog.launchID(for: brand) == app.launchID
                    || app.name.caseInsensitiveCompare(catalog.name) == .orderedSame)
        }
    }

    func setShown(_ app: TVApp, _ shown: Bool) {
        appChoices[app.name.lowercased()] = shown
    }

    var watchApps: [(app: TVApp, style: CatalogApp?)] {
        allApps.filter { isShown($0.app) }
    }

    func refreshApps() async {
        guard let driver else { return }
        if let apps = await driver.installedApps() {
            installedApps = apps
        }
    }

    // MARK: TVDriverDelegate

    func driver(_ driver: TVDriver, didChangeState state: ConnectionState) {
        guard driver === self.driver else { return }
        guard !isConnectionPaused else { self.state = .idle; return }
        self.state = state
        if case .failed = state, let current {
            relocate(current)
        }
        if state == .connected, installedApps == nil {
            Task { await refreshApps() }
        }
    }

    func driver(_ driver: TVDriver, didUpdateDevice device: TVDevice) {
        guard let i = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[i] = device
        DeviceStore.save(devices)
    }
}
