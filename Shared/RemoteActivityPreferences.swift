import Foundation

struct RemoteActivityOptions: Codable, Equatable {
    var automatic = true
    var dismissedDeviceID: String?
    var disconnectedDeviceID: String?

    func allowsAutomatic(for id: String) -> Bool {
        automatic && dismissedDeviceID != id && disconnectedDeviceID != id
    }

    mutating func apply(_ event: RemoteActivityActionEvent) {
        dismissedDeviceID = event.deviceID
        if event.action == .disconnect { disconnectedDeviceID = event.deviceID }
    }
}

enum RemoteActivityAction: String, Sendable { case dismiss, disconnect }

struct RemoteActivityActionEvent: Sendable {
    let action: RemoteActivityAction
    let deviceID: String
}

enum RemoteActivityPersistence {
    static let sessionKey = "remoteActivitySession.v1"
    static let optionsKey = "remoteActivityOptions.v1"
    static let selectedDeviceKey = "currentDevice.v1"
    static let actionNotification = Notification.Name("OpenRemote.remoteActivityAction")

    static func options(_ defaults: UserDefaults = .standard) -> RemoteActivityOptions {
        defaults.data(forKey: optionsKey).flatMap { try? JSONDecoder().decode(RemoteActivityOptions.self, from: $0) }
            ?? RemoteActivityOptions()
    }

    static func save(_ options: RemoteActivityOptions, to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(options), forKey: optionsKey)
    }

    /// The nonce is checked again in the app process. Old Island buttons cannot
    /// disconnect a newer TV/session, and a second tap has no session to replay.
    static func authorize(_ action: RemoteActivityAction, sessionID: UUID,
                          session: RemoteActivitySession?, selectedID: String?, at now: Date) -> RemoteActivityActionEvent? {
        guard let session, session.id == sessionID, session.deviceID == selectedID,
              action == .dismiss || session.isValid(for: selectedID, at: now) else { return nil }
        return RemoteActivityActionEvent(action: action, deviceID: session.deviceID)
    }

    @MainActor
    static func apply(_ action: RemoteActivityAction, sessionID: UUID,
                      defaults: UserDefaults = .standard, now: Date = Date()) {
        let session = defaults.data(forKey: sessionKey)
            .flatMap { try? JSONDecoder().decode(RemoteActivitySession.self, from: $0) }
        guard let event = authorize(action, sessionID: sessionID, session: session,
                                    selectedID: defaults.string(forKey: selectedDeviceKey), at: now) else { return }
        var options = options(defaults)
        options.apply(event)
        save(options, to: defaults)
        defaults.removeObject(forKey: sessionKey)
        NotificationCenter.default.post(name: actionNotification, object: event)
    }
}
