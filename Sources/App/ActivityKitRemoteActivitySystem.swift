#if os(iOS)
import ActivityKit
import Foundation

@MainActor
final class ActivityKitRemoteActivitySystem: RemoteActivitySystem {
    let allowsSystemAccess: Bool

    init(allowsSystemAccess: Bool = true) { self.allowsSystemAccess = allowsSystemAccess }

    var isEnabled: Bool { allowsSystemAccess && ActivityAuthorizationInfo().areActivitiesEnabled }
    var activities: [any RemoteActivityHandle] {
        guard allowsSystemAccess else { return [] }
        return Activity<RemoteActivityAttributes>.activities.map(ActivityKitRemoteActivityHandle.init)
    }

    func request(_ session: RemoteActivitySession) throws -> any RemoteActivityHandle {
        guard isEnabled else { throw CancellationError() }
        let activity = try Activity.request(attributes: RemoteActivityAttributes(sessionID: session.id),
                                            content: Self.content(for: session), pushType: nil)
        return ActivityKitRemoteActivityHandle(activity)
    }

    static func content(for session: RemoteActivitySession) -> ActivityContent<RemoteActivityAttributes.ContentState> {
        ActivityContent(state: .init(tvName: session.tvName, expiresAt: session.expiresAt), staleDate: session.expiresAt)
    }
}

@MainActor
private final class ActivityKitRemoteActivityHandle: RemoteActivityHandle {
    let activity: Activity<RemoteActivityAttributes>
    private var observation: Task<Void, Never>?
    var onEnded: (() -> Void)? {
        didSet {
            observation?.cancel()
            guard onEnded != nil else { return }
            let activity = self.activity
            observation = Task { @MainActor [weak self] in
                for await state in activity.activityStateUpdates {
                    guard !Task.isCancelled else { return }
                    if state == .ended || state == .dismissed { self?.onEnded?(); return }
                }
            }
        }
    }

    init(_ activity: Activity<RemoteActivityAttributes>) { self.activity = activity }
    var id: String { activity.id }
    var sessionID: UUID { activity.attributes.sessionID }
    var isActive: Bool { activity.activityState == .active || activity.activityState == .stale }
    func update(_ session: RemoteActivitySession) async { await activity.update(ActivityKitRemoteActivitySystem.content(for: session)) }
    func end() async { await activity.end(nil, dismissalPolicy: .immediate) }
    deinit { observation?.cancel() }
}
#endif
