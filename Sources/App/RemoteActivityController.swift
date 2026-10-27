import Foundation
import Observation

@MainActor
protocol RemoteActivityHandle: AnyObject {
    var id: String { get }
    var sessionID: UUID { get }
    var isActive: Bool { get }
    var onEnded: (() -> Void)? { get set }
    func update(_ session: RemoteActivitySession) async
    func end() async
}

@MainActor
protocol RemoteActivitySystem: AnyObject {
    var isEnabled: Bool { get }
    var activities: [any RemoteActivityHandle] { get }
    func request(_ session: RemoteActivitySession) throws -> any RemoteActivityHandle
}

@MainActor
@Observable
final class RemoteActivityController {
    private(set) var session: RemoteActivitySession?
    private(set) var isBusy = false
    private(set) var options: RemoteActivityOptions
    var errorMessage: String?

    @ObservationIgnored private let system: any RemoteActivitySystem
    @ObservationIgnored private let load: () -> Data?
    @ObservationIgnored private let save: (Data?) -> Void
    @ObservationIgnored private let loadOptions: () -> RemoteActivityOptions
    @ObservationIgnored private let saveOptions: (RemoteActivityOptions) -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: (TimeInterval) async throws -> Void
    @ObservationIgnored private var activity: (any RemoteActivityHandle)?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var selectedID: String?
    @ObservationIgnored private var lastPublished = Date.distantPast
    private static let storageKey = RemoteActivityPersistence.sessionKey

    init(system: any RemoteActivitySystem,
         load: (() -> Data?)? = nil,
         save: ((Data?) -> Void)? = nil,
         loadOptions: @escaping () -> RemoteActivityOptions = { RemoteActivityPersistence.options() },
         saveOptions: @escaping (RemoteActivityOptions) -> Void = { RemoteActivityPersistence.save($0) },
         now: @escaping () -> Date = Date.init,
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.system = system
        self.load = load ?? { UserDefaults.standard.data(forKey: Self.storageKey) }
        self.save = save ?? { UserDefaults.standard.set($0, forKey: Self.storageKey) }
        self.loadOptions = loadOptions
        self.saveOptions = saveOptions
        options = loadOptions()
        self.now = now
        self.sleep = sleep
    }

    /// Restore a known session. Automatic creation happens separately on foreground use.
    func reconcile(selectedID: String?) {
        reloadOptions()
        if isBusy {
            if self.selectedID != selectedID { selectionChanged(to: selectedID) }
            return
        }
        self.selectedID = selectedID
        let stored = load()
            .flatMap { try? JSONDecoder().decode(RemoteActivitySession.self, from: $0) }
        let known = system.activities
        guard let stored, options.dismissedDeviceID != selectedID, options.disconnectedDeviceID != selectedID,
              stored.isValid(for: selectedID, at: now()),
              let match = known.first(where: {
                  $0.sessionID == stored.id && $0.isActive
              }) else { unpin(); return }
        session = stored
        activity = match
        lastPublished = stored.lastInteraction
        observe(match)
        end(known.filter { $0.id != match.id })
        publish()
    }

    func selectionChanged(to id: String?) {
        guard selectedID != id else { return }
        selectedID = id
        unpin()
    }

    func reloadOptions() { options = loadOptions() }

    func resume(_ id: String) {
        reloadOptions()
        if options.dismissedDeviceID == id { options.dismissedDeviceID = nil }
        if options.disconnectedDeviceID == id { options.disconnectedDeviceID = nil }
        saveOptions(options)
    }

    func dismiss() {
        if let selectedID {
            options.apply(RemoteActivityActionEvent(action: .dismiss, deviceID: selectedID))
            saveOptions(options)
        }
        unpin()
    }

    func pauseConnection(_ id: String) {
        reloadOptions()
        options.apply(RemoteActivityActionEvent(action: .disconnect, deviceID: id))
        saveOptions(options)
        unpin()
    }

    func setAutomatic(_ enabled: Bool, device: TVDevice?) {
        options.automatic = enabled
        if enabled { options.dismissedDeviceID = nil }
        saveOptions(options)
        if !enabled { unpin() }
        else { ensureAutomatic(device) }
    }

    func ensureAutomatic(_ device: TVDevice?) {
        reloadOptions()
        guard let device, options.allowsAutomatic(for: device.id), session == nil, !isBusy, system.isEnabled else { return }
        pin(device, reportErrors: false)
    }

    func pin(_ device: TVDevice, reportErrors: Bool = true) {
        guard !isBusy else { return }
        guard system.isEnabled else {
            if reportErrors { errorMessage = "Live Activities are turned off. Enable them for Open Remote in Settings to pin a remote." }
            return
        }
        selectedID = device.id
        generation += 1
        let token = generation
        let previous = operation
        let known = system.activities
        activity?.onEnded = nil
        activity = nil
        session = nil
        persist()
        isBusy = true
        operation = Task { @MainActor [weak self] in
            defer { if self?.generation == token { self?.isBusy = false } }
            await previous?.value
            for old in known { await old.end() }
            guard let self, token == self.generation, self.selectedID == device.id, !Task.isCancelled else { return }
            let session = RemoteActivitySession(deviceID: device.id, tvName: device.name, brandName: device.brand.shortName, now: self.now())
            do {
                let activity = try self.system.request(session)
                self.session = session
                self.activity = activity
                self.options.dismissedDeviceID = nil
                self.saveOptions(self.options)
                self.persist()
                self.lastPublished = session.lastInteraction
                self.observe(activity)
                self.armExpiry()
            } catch {
                self.session = nil
                self.activity = nil
                self.persist()
                if reportErrors { self.errorMessage = "Couldn’t pin the remote. Check that Live Activities are allowed, then try again." }
            }
        }
    }

    func unpin() {
        generation += 1
        operation?.cancel()
        expiry?.cancel()
        activity?.onEnded = nil
        session = nil
        activity = nil
        isBusy = false
        persist()
        end(system.activities)
    }

    /// Record locally on every command; publish at most once a minute while active.
    func noteInteraction() {
        guard var updated = session else { return }
        guard updated.isValid(for: selectedID, at: now()), updated.recordInteraction(at: now()) else { unpin(); return }
        session = updated
        if now().timeIntervalSince(lastPublished) >= 60 { publish() }
    }

    /// Flush the precise deadline before suspension; no background execution is requested.
    func sceneDidEnterBackground() { publish() }

    func accepts(_ url: URL, selectedID: String?) -> Bool {
        guard let session, session.accepts(url, selectedDeviceID: selectedID, at: now()),
              let activity, activity.isActive else { return false }
        return true
    }

    private func persist() {
        if let session, let data = try? JSONEncoder().encode(session) {
            save(data)
        } else { save(nil) }
    }

    private func publish() {
        guard let session, let activity else { return }
        guard session.isValid(for: selectedID, at: now()) else { unpin(); return }
        persist()
        lastPublished = now()
        let token = generation
        let previous = operation
        operation = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, token == self.generation, !Task.isCancelled else { return }
            await activity.update(session)
        }
        armExpiry()
    }

    private func armExpiry() {
        expiry?.cancel()
        guard let session else { return }
        let id = session.id
        let delay = max(0, session.expiresAt.timeIntervalSince(now()))
        let sleep = self.sleep
        expiry = Task { @MainActor [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, self.session?.id == id else { return }
            if self.session?.isValid(for: self.selectedID, at: self.now()) == true { self.publish() }
            else { self.unpin() }
        }
    }

    private func observe(_ activity: any RemoteActivityHandle) {
        self.activity?.onEnded = nil
        activity.onEnded = { [weak self, weak activity] in
            guard let self, let activity, self.activity?.id == activity.id else { return }
            self.dismiss()
        }
    }

    private func end(_ activities: [any RemoteActivityHandle]) {
        guard !activities.isEmpty else { return }
        let previous = operation
        operation = Task {
            await previous?.value
            for activity in activities { await activity.end() }
        }
    }

    deinit { operation?.cancel(); expiry?.cancel() }
}
