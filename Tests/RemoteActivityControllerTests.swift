import Foundation
import Testing
@testable import JoystickCore

@MainActor
private final class FakeRemoteActivity: RemoteActivityHandle {
    let id = UUID().uuidString
    let sessionID: UUID
    var isActive = true
    var onEnded: (() -> Void)?
    var updates: [RemoteActivitySession] = []
    var delayEnd = false
    var endStarted = false
    var finishEnd: CheckedContinuation<Void, Never>?

    init(sessionID: UUID) { self.sessionID = sessionID }
    func update(_ session: RemoteActivitySession) async { updates.append(session) }
    func end() async {
        guard isActive else { return }
        endStarted = true
        if delayEnd { await withCheckedContinuation { finishEnd = $0 } }
        isActive = false
        onEnded?()
    }
    func dismiss() { isActive = false; onEnded?() }
}

@MainActor
private final class FakeRemoteActivitySystem: RemoteActivitySystem {
    var isEnabled = true
    var handles: [FakeRemoteActivity] = []
    var requests: [RemoteActivitySession] = []
    var failRequest = false
    var activities: [any RemoteActivityHandle] { handles.filter(\.isActive) }
    func request(_ session: RemoteActivitySession) throws -> any RemoteActivityHandle {
        if failRequest { throw CancellationError() }
        requests.append(session)
        let activity = FakeRemoteActivity(sessionID: session.id)
        handles.append(activity)
        return activity
    }
}

@MainActor
private final class SessionFixture {
    var data: Data?
    var now = Date(timeIntervalSince1970: 1_000_000)
    let system = FakeRemoteActivitySystem()
    let device = TVDevice(name: "Living Room LG", brand: .lg, host: "192.0.2.10")

    func controller() -> RemoteActivityController {
        RemoteActivityController(system: system, load: { self.data }, save: { self.data = $0 },
                                 now: { self.now }, sleep: { _ in throw CancellationError() })
    }
    func restoreFixture() throws -> (RemoteActivitySession, FakeRemoteActivity) {
        let session = RemoteActivitySession(deviceID: device.id, tvName: device.name, now: now)
        data = try JSONEncoder().encode(session)
        let handle = FakeRemoteActivity(sessionID: session.id)
        system.handles.append(handle)
        return (session, handle)
    }
}

@MainActor
private func activityEventually(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
    #expect(condition())
}

@Suite("Pinned remote lifecycle", .serialized)
@MainActor
struct RemoteActivityControllerTests {
    @Test func restorationReusesOnlyTheMatchingActivity() async throws {
        let f = SessionFixture()
        let (session, handle) = try f.restoreFixture()
        let orphan = FakeRemoteActivity(sessionID: UUID())
        f.system.handles.append(orphan)
        let controller = f.controller()
        controller.reconcile(selectedID: f.device.id)
        #expect(controller.session == session)
        await activityEventually { !orphan.isActive && !handle.updates.isEmpty }
        #expect(handle.isActive)
        #expect(f.system.requests.isEmpty)
        controller.unpin()
    }

    @Test func noStoredPinNeverStartsAnActivity() async {
        let f = SessionFixture()
        let orphan = FakeRemoteActivity(sessionID: UUID())
        f.system.handles.append(orphan)
        let controller = f.controller()
        controller.reconcile(selectedID: f.device.id)
        await activityEventually { !orphan.isActive }
        #expect(controller.session == nil)
        #expect(f.system.requests.isEmpty)
        #expect(f.data == nil)
    }

    @Test func pinIsExplicitAndUnpinInvalidatesTheLinkImmediately() async throws {
        let f = SessionFixture()
        let controller = f.controller()
        controller.pin(f.device)
        await activityEventually { !controller.isBusy }
        let session = try #require(controller.session)
        let link = try #require(RemoteActivityLink.url(for: session.id))
        #expect(controller.accepts(link, selectedID: f.device.id))
        #expect(f.system.requests.count == 1)
        controller.unpin()
        #expect(!controller.accepts(link, selectedID: f.device.id))
        #expect(f.data == nil)
        await activityEventually { f.system.activities.isEmpty }
    }

    @Test(arguments: [false, true])
    func changingTVWhileCleanupWaitsCannotPinTheOldTV(viaForeground: Bool) async {
        let f = SessionFixture()
        let orphan = FakeRemoteActivity(sessionID: UUID())
        orphan.delayEnd = true
        f.system.handles.append(orphan)
        let controller = f.controller()
        controller.pin(f.device)
        await activityEventually { orphan.endStarted }
        if viaForeground { controller.reconcile(selectedID: "roku@192.0.2.20") }
        else { controller.selectionChanged(to: "roku@192.0.2.20") }
        orphan.finishEnd?.resume()
        await activityEventually { !orphan.isActive }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(f.system.requests.isEmpty)
        #expect(controller.session == nil)
        #expect(!controller.isBusy)
    }

    @Test func systemDismissalCannotBeUndoneByInteractionOrRelaunch() async throws {
        let f = SessionFixture()
        let (_, handle) = try f.restoreFixture()
        let controller = f.controller()
        controller.reconcile(selectedID: f.device.id)
        handle.dismiss()
        controller.noteInteraction()
        controller.reconcile(selectedID: f.device.id)
        #expect(controller.session == nil)
        #expect(f.data == nil)
        #expect(f.system.requests.isEmpty)
    }

    @Test func backgroundFlushStoresTheLatestInputDeadline() async throws {
        let f = SessionFixture()
        let (_, handle) = try f.restoreFixture()
        let controller = f.controller()
        controller.reconcile(selectedID: f.device.id)
        await activityEventually { handle.updates.count == 1 }
        f.now = f.now.addingTimeInterval(10)
        controller.noteInteraction()
        #expect(handle.updates.count == 1) // Hold repeats don't publish each time.
        controller.sceneDidEnterBackground()
        await activityEventually { handle.updates.count == 2 }
        let data = try #require(f.data)
        let stored = try JSONDecoder().decode(RemoteActivitySession.self, from: data)
        #expect(stored.expiresAt == f.now.addingTimeInterval(1800))
        #expect(handle.updates.last == stored)
        controller.unpin()
    }

    @Test func expiryOnReturnRemovesTheActivityWithoutRestartingIt() async throws {
        let f = SessionFixture()
        let (session, handle) = try f.restoreFixture()
        let controller = f.controller()
        controller.reconcile(selectedID: f.device.id)
        f.now = session.expiresAt
        controller.reconcile(selectedID: f.device.id)
        #expect(controller.session == nil)
        #expect(f.data == nil)
        await activityEventually { !handle.isActive }
        #expect(f.system.requests.isEmpty)
    }

    @Test func deniedOrFailedPinShowsAnErrorAndKeepsNoSession() async {
        for denied in [true, false] {
            let f = SessionFixture()
            f.system.isEnabled = !denied
            f.system.failRequest = !denied
            let controller = f.controller()
            controller.pin(f.device)
            await activityEventually { !controller.isBusy }
            #expect(controller.errorMessage != nil)
            #expect(controller.session == nil)
            #expect(f.data == nil)
        }
    }
}
