import Foundation
import Testing
@testable import JoystickCore

@Suite("Pinned remote sessions")
struct RemoteActivitySessionTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func generalRemoteAndLegacyEyesFreeLinksHaveDistinctDestinations() throws {
        let id = UUID()
        let normal = try #require(RemoteActivityLink.url(for: id))
        let stick = try #require(RemoteActivityLink.url(for: id, eyesFree: true))
        #expect(normal.host == "remote")
        #expect(!RemoteActivityLink.opensEyesFree(normal))
        #expect(RemoteActivityLink.opensEyesFree(stick))
        #expect(RemoteActivityLink.sessionID(in: normal) == id)
        #expect(RemoteActivityLink.sessionID(in: stick) == id)
    }

    @Test func expandedActionsRequireTheCurrentSelectedSessionAndCannotReplay() {
        let session = RemoteActivitySession(deviceID: "lg@192.0.2.10", tvName: "LG", now: start)
        #expect(RemoteActivityPersistence.authorize(.disconnect, sessionID: session.id, session: session,
                                                   selectedID: session.deviceID, at: start)?.deviceID == session.deviceID)
        #expect(RemoteActivityPersistence.authorize(.disconnect, sessionID: UUID(), session: session,
                                                   selectedID: session.deviceID, at: start) == nil)
        #expect(RemoteActivityPersistence.authorize(.disconnect, sessionID: session.id, session: session,
                                                   selectedID: "roku@192.0.2.20", at: start) == nil)
        #expect(RemoteActivityPersistence.authorize(.disconnect, sessionID: session.id, session: nil,
                                                   selectedID: session.deviceID, at: start) == nil)
        #expect(RemoteActivityPersistence.authorize(.disconnect, sessionID: session.id, session: session,
                                                   selectedID: session.deviceID, at: session.expiresAt) == nil)
        #expect(RemoteActivityPersistence.authorize(.dismiss, sessionID: session.id, session: session,
                                                   selectedID: session.deviceID, at: session.expiresAt) != nil)
    }

    @Test func dismissAndDisconnectHaveDifferentConnectionEffects() {
        var dismissed = RemoteActivityOptions()
        dismissed.apply(RemoteActivityActionEvent(action: .dismiss, deviceID: "test"))
        #expect(!dismissed.allowsAutomatic(for: "test"))
        #expect(dismissed.disconnectedDeviceID == nil)
        var disconnected = RemoteActivityOptions()
        disconnected.apply(RemoteActivityActionEvent(action: .disconnect, deviceID: "test"))
        #expect(!disconnected.allowsAutomatic(for: "test"))
        #expect(disconnected.disconnectedDeviceID == "test")
    }

    @Test func shortcutContainsOnlyAnOpaqueNonce() throws {
        let session = RemoteActivitySession(deviceID: "lg@192.0.2.10", tvName: "Living Room", now: start)
        let url = try #require(RemoteActivityLink.url(for: session.id))
        #expect(!url.absoluteString.contains("192.0.2.10"))
        #expect(!url.absoluteString.contains("Living"))
        #expect(session.accepts(url, selectedDeviceID: session.deviceID, at: start))
    }

    @Test func anotherSelectionOrSessionCannotBeOpened() throws {
        let session = RemoteActivitySession(deviceID: "lg@192.0.2.10", tvName: "LG", now: start)
        let url = try #require(RemoteActivityLink.url(for: session.id))
        #expect(!session.accepts(url, selectedDeviceID: "roku@192.0.2.11", at: start))
        #expect(!session.accepts(url, selectedDeviceID: nil, at: start))
        let other = try #require(RemoteActivityLink.url(for: UUID()))
        #expect(!session.accepts(other, selectedDeviceID: session.deviceID, at: start))
    }

    @Test func expiredLinksCannotOpenOrRenew() throws {
        var session = RemoteActivitySession(deviceID: "roku@192.0.2.11", tvName: "Roku", now: start)
        let url = try #require(RemoteActivityLink.url(for: session.id))
        let end = start.addingTimeInterval(30 * 60)
        #expect(session.isValid(for: session.deviceID, at: end.addingTimeInterval(-1)))
        #expect(!session.accepts(url, selectedDeviceID: session.deviceID, at: end))
        let renewed = session.recordInteraction(at: end)
        #expect(!renewed)
        #expect(session.expiresAt == end)
    }

    @Test func interactionExtendsInactivityButNotTheEightHourLimit() {
        var session = RemoteActivitySession(deviceID: "test", tvName: "TV", now: start)
        for minute in stride(from: 20, through: 470, by: 20) {
            let renewed = session.recordInteraction(at: start.addingTimeInterval(Double(minute) * 60))
            #expect(renewed)
        }
        #expect(session.expiresAt == start.addingTimeInterval(8 * 60 * 60))
        let renewed = session.recordInteraction(at: session.expiresAt)
        #expect(!renewed)
    }

    @Test func backwardsClockCannotExtendTheSession() {
        var session = RemoteActivitySession(deviceID: "test", tvName: "TV", now: start)
        let renewed = session.recordInteraction(at: start.addingTimeInterval(-1))
        #expect(!renewed)
        #expect(session.lastInteraction == start)
    }

    @Test func localSessionSurvivesRelaunchWithTheSameDeadline() throws {
        var session = RemoteActivitySession(deviceID: "test", tvName: "TV", now: start)
        session.recordInteraction(at: start.addingTimeInterval(600))
        let decoded = try JSONDecoder().decode(RemoteActivitySession.self, from: JSONEncoder().encode(session))
        #expect(decoded == session)
        #expect(decoded.expiresAt == start.addingTimeInterval(2400))
    }

    @Test func malformedAndOverloadedLinksAreRejected() throws {
        let id = UUID().uuidString
        let invalid = ["https://eyes-free?session=\(id)", "openremote://other?session=\(id)",
                       "openremote://eyes-free/other?session=\(id)", "openremote://eyes-free?session=\(id)#fragment",
                       "openremote://eyes-free?session=\(id)&session=\(id)", "openremote://eyes-free?session=\(id)&command=power",
                       "openremote://user@eyes-free?session=\(id)", "openremote://eyes-free:80?session=\(id)",
                       "openremote://eyes-free?session=invalid", "openremote://eyes-free"]
        for raw in invalid {
            let url = try #require(URL(string: raw))
            #expect(RemoteActivityLink.sessionID(in: url) == nil)
        }
    }

    @Test func evaluationSchemeIsIsolatedFromThePublicApp() throws {
        let id = UUID()
        let url = try #require(RemoteActivityLink.url(for: id, scheme: "openremotetest"))
        #expect(RemoteActivityLink.sessionID(in: url, scheme: "openremotetest") == id)
        #expect(RemoteActivityLink.sessionID(in: url, scheme: "openremote") == nil)
    }
}
