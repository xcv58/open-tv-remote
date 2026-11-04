#if os(iOS)
import ActivityKit
import AppIntents
import Foundation

struct DismissRemoteActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Dismiss remote shortcut"
    static var openAppWhenRun = false
    static var isDiscoverable = false
    @Parameter(title: "Session") var session: String

    init() {}
    init(sessionID: UUID) { session = sessionID.uuidString }

    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: session) { await RemoteActivityIntentAction.perform(.dismiss, sessionID: id) }
        return .result()
    }
}

struct DisconnectRemoteActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Disconnect TV remote"
    static var openAppWhenRun = false
    static var isDiscoverable = false
    @Parameter(title: "Session") var session: String

    init() {}
    init(sessionID: UUID) { session = sessionID.uuidString }

    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: session) { await RemoteActivityIntentAction.perform(.disconnect, sessionID: id) }
        return .result()
    }
}

@MainActor
private enum RemoteActivityIntentAction {
    static func perform(_ action: RemoteActivityAction, sessionID: UUID) async {
        RemoteActivityPersistence.apply(action, sessionID: sessionID)
        // Dismiss even an expired card, but never touch another session's activity.
        let activities = Activity<RemoteActivityAttributes>.activities.filter { $0.attributes.sessionID == sessionID }
        for activity in activities { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
#endif
