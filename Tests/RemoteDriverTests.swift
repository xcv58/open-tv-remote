import Foundation
import Testing
@testable import JoystickCore

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
    #expect(condition())
}

@Suite("Interactive transport ordering and recovery", .serialized)
@MainActor
struct RemoteDriverTests {
    @Test func rokuDisconnectInvalidatesEveryQueuedNormalCommandAndOldResponse() async {
        let driver = await connectedRoku()
        driver.send(.up)
        await waitUntil { LocalHTTP.started.count == 1 }
        driver.send(.down)
        driver.send(.left)
        driver.disconnect()
        LocalHTTP.complete("/keypress/Up")
        try? await Task.sleep(for: .milliseconds(30))
        #expect(LocalHTTP.started == ["/keypress/Up"])
        #expect(driver.state == .idle)
        LocalHTTP.reset()
    }

    private func connectedRoku() async -> RokuDriver {
        LocalHTTP.reset()
        let driver = RokuDriver(device: TVDevice(name: "Test Roku", brand: .roku, host: "192.0.2.10"))
        driver.connect()
        await waitUntil { driver.state == .connected }
        return driver
    }

    @Test func rokuNormalAndInteractiveCommandsShareTheirOrder() async {
        let driver = await connectedRoku()
        driver.send(.up)
        await waitUntil { LocalHTTP.started.count == 1 }
        driver.send(.down)
        let request = RemoteInputRequest()
        let interactive = Task { await driver.sendInteractive(.back, request: request) }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(LocalHTTP.started == ["/keypress/Up"])
        LocalHTTP.complete("/keypress/Up")
        await waitUntil { LocalHTTP.started.count == 2 }
        #expect(LocalHTTP.started.last == "/keypress/Down")
        LocalHTTP.complete("/keypress/Down")
        await waitUntil { LocalHTTP.started.count == 3 }
        #expect(LocalHTTP.started == ["/keypress/Up", "/keypress/Down", "/keypress/Back"])
        LocalHTTP.complete("/keypress/Back")
        await interactive.value
        #expect(LocalHTTP.completions.isEmpty)
    }

    @Test func rokuDropsReleasedJoystickInputWaitingBehindNormalCommands() async {
        let driver = await connectedRoku()
        driver.send(.up)
        await waitUntil { LocalHTTP.started.count == 1 }
        let request = RemoteInputRequest()
        let interactive = Task { await driver.sendInteractive(.right, request: request) }
        try? await Task.sleep(for: .milliseconds(20))
        request.cancel()
        LocalHTTP.complete("/keypress/Up")
        await interactive.value
        #expect(LocalHTTP.started == ["/keypress/Up"])
        #expect(driver.state == .connected)
    }

    @Test func rokuAllowsTheNextNormalCommandAfterDiscardingStaleInput() async {
        let driver = await connectedRoku()
        driver.send(.up)
        await waitUntil { LocalHTTP.started.count == 1 }
        let request = RemoteInputRequest()
        let interactive = Task { await driver.sendInteractive(.right, request: request) }
        try? await Task.sleep(for: .milliseconds(20))
        driver.send(.back)
        request.cancel()
        LocalHTTP.complete("/keypress/Up")
        await interactive.value
        await waitUntil { LocalHTTP.started.count == 2 }
        #expect(LocalHTTP.started == ["/keypress/Up", "/keypress/Back"])
        LocalHTTP.complete("/keypress/Back")
        await waitUntil { LocalHTTP.completions.isEmpty }
    }

    @Test func acceptedOKSurvivesLiftWhileStaleRokuMovementIsDiscarded() async {
        let driver = await connectedRoku()
        driver.send(.up)
        await waitUntil { LocalHTTP.started.count == 1 }
        let sender = JoystickSender(send: { key, request in
            await driver.sendInteractive(key, request: request)
        })
        sender.hold(.right)
        try? await Task.sleep(for: .milliseconds(20))
        sender.release()
        sender.press(.select)
        sender.release()
        LocalHTTP.complete("/keypress/Up")
        await waitUntil { LocalHTTP.started.count == 2 }
        #expect(LocalHTTP.started == ["/keypress/Up", "/keypress/Select"])
        LocalHTTP.complete("/keypress/Select")
        await waitUntil { LocalHTTP.completions.isEmpty }
        sender.stop()
    }

    @Test func rokuRetainsActiveOKWhenTheNextGestureBegins() async {
        let driver = await connectedRoku()
        driver.send(.up)
        await waitUntil { LocalHTTP.started.count == 1 }
        var accepted: RemoteInputRequest?
        let sender = JoystickSender(send: { key, request in
            if key == .select { accepted = request }
            await driver.sendInteractive(key, request: request)
        })
        sender.press(.select)
        sender.release()
        await waitUntil { accepted != nil }
        sender.hold(.right)
        #expect(accepted?.isCancelled == false)
        LocalHTTP.complete("/keypress/Up")
        await waitUntil { LocalHTTP.started.count == 2 }
        #expect(LocalHTTP.started == ["/keypress/Up", "/keypress/Select"])
        LocalHTTP.complete("/keypress/Select")
        await waitUntil { LocalHTTP.started.count == 3 }
        #expect(LocalHTTP.started == ["/keypress/Up", "/keypress/Select", "/keypress/Right"])
        sender.release()
        LocalHTTP.complete("/keypress/Right")
        await waitUntil { LocalHTTP.completions.isEmpty }
        sender.stop()
    }

    @Test func cancelledRokuResponseCannotRestoreDisconnectedState() async {
        let driver = await connectedRoku()
        let request = RemoteInputRequest()
        let interactive = Task { await driver.sendInteractive(.right, request: request) }
        await waitUntil { LocalHTTP.started.count == 1 }
        request.cancel()
        driver.disconnect()
        LocalHTTP.complete("/keypress/Right")
        await interactive.value
        #expect(driver.state == .idle)
    }

    private func connectLG() -> (LGDriver, LocalWebSocket, LocalWebSocket) {
        LocalWebSocket.instances = []
        let driver = LGDriver(device: TVDevice(name: "Test LG", brand: .lg, host: "192.0.2.20", token: "test"))
        driver.connect()
        let control = LocalWebSocket.instances.last!
        control.onText?("{\"type\":\"registered\",\"id\":\"register_0\",\"payload\":{}}")
        respondToPointerRequest(control)
        return (driver, control, LocalWebSocket.instances.last!)
    }

    private func respondToPointerRequest(_ control: LocalWebSocket) {
        let request = JSON.parse(control.sent.last!)!
        let id = request["id"] as! String
        control.onText?("{\"id\":\"\(id)\",\"payload\":{\"socketPath\":\"ws://192.0.2.20/pointer\"}}")
    }

    @Test func lgCursorUsesPointerPacketsRatherThanDirectionalKeys() async {
        let (driver, _, pointer) = connectLG()
        #expect(driver.supportsCursor)
        #expect(await driver.sendCursor(.move(dx: 12.5, dy: -3), request: RemoteInputRequest()))
        #expect(await driver.sendCursor(.scroll(dx: 0, dy: 1), request: RemoteInputRequest()))
        #expect(await driver.sendCursor(.click, request: RemoteInputRequest()))
        #expect(pointer.sent == ["type:move\ndx:12.500\ndy:-3.000\ndown:0\n\n",
                                 "type:scroll\ndx:0.000\ndy:1.000\n\n", "type:click\n\n"])
        driver.disconnect()
    }

    @Test func lgCursorRejectsOversizedWireMovesInsteadOfSendingThem() async {
        let (driver, _, pointer) = connectLG()
        #expect(!(await driver.sendCursor(.move(dx: 500, dy: 0), request: RemoteInputRequest())))
        #expect(pointer.sent.isEmpty)
        #expect(await driver.sendCursor(.move(dx: 96, dy: 0), request: RemoteInputRequest()))
        #expect(pointer.sent == ["type:move\ndx:96.000\ndy:0.000\ndown:0\n\n"])
        driver.disconnect()
    }

    @Test func lgScrollJitterNeverSendsZeroWheelPacketsOrEarnsFeedback() async {
        let (driver, _, pointer) = connectLG()
        var feedback: [RemoteInputRequest.Feedback] = []
        let sender = CursorSender(send: { command, request in
            let sent = await driver.sendCursor(command, request: request)
            if sent { feedback.append(request.feedback) }
            return sent
        })
        for rawDelta in [0.001, -0.001, 4.5, 4.5, 9.0] {
            guard case let .scroll(dx, dy)? = CursorMotion.scroll(dx: 0, dy: rawDelta, reversed: false) else {
                Issue.record("Expected nonzero raw scroll input"); continue
            }
            sender.scroll(dx: dx, dy: dy)
        }
        await waitUntil { sender.scrollActivity == 1 }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(pointer.sent == ["type:scroll\ndx:0.000\ndy:-1.000\n\n"])
        #expect(feedback == [.firm])
        #expect(sender.scrollActivity == 1)
        sender.stop(); driver.disconnect()
    }

    @Test func lgCursorRejectsInvalidAndCancelledInput() async {
        let (driver, _, pointer) = connectLG()
        let cancelled = RemoteInputRequest()
        cancelled.cancel()
        #expect(!(await driver.sendCursor(.click, request: cancelled)))
        #expect(!(await driver.sendCursor(.move(dx: .nan, dy: 1), request: RemoteInputRequest())))
        #expect(!(await driver.sendCursor(.scroll(dx: 0, dy: .infinity), request: RemoteInputRequest())))
        #expect(pointer.sent.isEmpty)
        driver.disconnect()
    }

    @Test func lgCursorRecoveryDropsTheDragAndPreservesCredentials() async {
        let (driver, control, pointer) = connectLG()
        pointer.peerClosed()
        #expect(!(await driver.sendCursor(.move(dx: 50, dy: 0), request: RemoteInputRequest())))
        respondToPointerRequest(control)
        let replacement = LocalWebSocket.instances.last!
        #expect(replacement !== pointer)
        #expect(replacement.sent.isEmpty)
        #expect(driver.device.token == "test")
        #expect(await driver.sendCursor(.move(dx: 3, dy: 2), request: RemoteInputRequest()))
        #expect(replacement.sent == ["type:move\ndx:3.000\ndy:2.000\ndown:0\n\n"])
        driver.disconnect()
    }

    @Test func lgCursorRetriesAfterALostPointerReplyAndIgnoresTheLateReply() async {
        let (driver, control, pointer) = connectLG()
        pointer.peerClosed()
        #expect(!(await driver.sendCursor(.move(dx: 1, dy: 0), request: RemoteInputRequest())))
        let expiredID = JSON.parse(control.sent.last!)!["id"] as! String
        #expect(!(await driver.sendCursor(.click, request: RemoteInputRequest())))
        #expect(driver.state == .connected && driver.device.token == "test")
        #expect(!(await driver.sendCursor(.move(dx: 2, dy: 0), request: RemoteInputRequest())))
        let freshRequest = control.sent.last!
        #expect((JSON.parse(freshRequest)!["id"] as! String) != expiredID)
        let socketCount = LocalWebSocket.instances.count
        control.onText?("{\"id\":\"\(expiredID)\",\"payload\":{\"socketPath\":\"ws://192.0.2.20/stale\"}}")
        #expect(LocalWebSocket.instances.count == socketCount)
        respondToPointerRequest(control)
        let replacement = LocalWebSocket.instances.last!
        #expect(replacement.sent.isEmpty)
        #expect(await driver.sendCursor(.move(dx: 3, dy: 0), request: RemoteInputRequest()))
        #expect(replacement.sent == ["type:move\ndx:3.000\ndy:0.000\ndown:0\n\n"])
        driver.disconnect()
    }

    @Test func lgCursorReplacesAPointerWhoseHandshakeTimedOut() async {
        LocalWebSocket.delayedOpenPaths = ["/pointer"]
        defer { LocalWebSocket.delayedOpenPaths = [] }
        let (driver, control, expired) = connectLG()
        #expect(!(await driver.sendCursor(.click, request: RemoteInputRequest())))
        #expect(driver.state == .connected && driver.device.token == "test")
        LocalWebSocket.delayedOpenPaths = []
        #expect(!(await driver.sendCursor(.scroll(dx: 0, dy: 1), request: RemoteInputRequest())))
        respondToPointerRequest(control)
        let replacement = LocalWebSocket.instances.last!
        #expect(replacement !== expired && replacement.sent.isEmpty)
        expired.completeHandshake()
        expired.peerClosed()
        #expect(await driver.sendCursor(.click, request: RemoteInputRequest()))
        #expect(replacement.sent == ["type:click\n\n"])
        driver.disconnect()
    }

    @Test func freshMotionCanRetryAnExpiredAcquisitionWithoutAButtonPress() async {
        let (driver, control, pointer) = connectLG()
        pointer.peerClosed()
        #expect(!(await driver.sendCursor(.move(dx: 1, dy: 0), request: RemoteInputRequest())))
        let expiredRequest = control.sent.last!
        try? await Task.sleep(for: .milliseconds(4050))
        #expect(!(await driver.sendCursor(.move(dx: 2, dy: 0), request: RemoteInputRequest())))
        #expect(control.sent.last != expiredRequest)
        respondToPointerRequest(control)
        let replacement = LocalWebSocket.instances.last!
        #expect(replacement.sent.isEmpty)
        #expect(await driver.sendCursor(.move(dx: 3, dy: 0), request: RemoteInputRequest()))
        #expect(replacement.sent.count == 1)
        driver.disconnect()
    }

    @Test func lgCursorSendFailureDropsOnlyThePointerAndRecoversOnNewInput() async {
        let (driver, control, pointer) = connectLG()
        pointer.sendSucceeds = false
        #expect(!(await driver.sendCursor(.click, request: RemoteInputRequest())))
        #expect(driver.state == .connected)
        #expect(driver.device.token == "test")
        #expect(!(await driver.sendCursor(.move(dx: 50, dy: 0), request: RemoteInputRequest())))
        respondToPointerRequest(control)
        let replacement = LocalWebSocket.instances.last!
        #expect(replacement !== pointer)
        #expect(replacement.sent.isEmpty)
        #expect(await driver.sendCursor(.click, request: RemoteInputRequest()))
        #expect(replacement.sent == ["type:click\n\n"])
        driver.disconnect()
    }

    @Test func lgCursorDoesNotPairOrReconnectWhenDisconnected() async {
        LocalWebSocket.instances = []
        let driver = LGDriver(device: TVDevice(name: "Test LG", brand: .lg, host: "192.0.2.20", token: "test"))
        #expect(!(await driver.sendCursor(.click, request: RemoteInputRequest())))
        #expect(LocalWebSocket.instances.isEmpty)
    }

    @Test func lgCursorWaitingForHandshakeIsCancelledByAChangedSession() async {
        LocalWebSocket.delayedOpenPaths = ["/pointer"]
        defer { LocalWebSocket.delayedOpenPaths = [] }
        let (driver, _, pointer) = connectLG()
        let request = RemoteInputRequest()
        let click = Task { await driver.sendCursor(.click, request: request) }
        try? await Task.sleep(for: .milliseconds(30))
        request.cancel()
        driver.disconnect()
        pointer.completeHandshake()
        #expect(!(await click.value))
        #expect(pointer.sent.isEmpty)
    }

    @Test func lgRecoversInputSocketWithoutReplayingTheTriggeringKey() async {
        let (driver, control, pointer) = connectLG()
        await driver.sendInteractive(.right, request: RemoteInputRequest())
        #expect(pointer.sent == ["type:button\nname:RIGHT\n\n"])
        pointer.peerClosed()
        let before = control.sent.count
        let left = Task { await driver.sendInteractive(.left, request: RemoteInputRequest()) }
        await waitUntil { control.sent.count == before + 1 }
        #expect(driver.state == .connected)
        var upEntered = false
        let up = Task { upEntered = true; await driver.sendInteractive(.up, request: RemoteInputRequest()) }
        await waitUntil { upEntered }
        #expect(control.sent.count == before + 1) // One recovery request in flight.
        respondToPointerRequest(control)
        await left.value
        await up.value
        let replacement = LocalWebSocket.instances.last!
        #expect(replacement !== pointer)
        #expect(replacement.sent.isEmpty)
        await driver.sendInteractive(.select, request: RemoteInputRequest())
        #expect(replacement.sent == ["type:button\nname:ENTER\n\n"])
    }

    @Test func lgRetainsOneShotUntilPointerCreation() async {
        LocalWebSocket.instances = []
        let driver = LGDriver(device: TVDevice(name: "Test LG", brand: .lg, host: "192.0.2.20", token: "test"))
        driver.connect()
        let control = LocalWebSocket.instances.last!
        control.onText?("{\"type\":\"registered\",\"id\":\"register_0\",\"payload\":{}}")
        var entered = false
        let operation = Task { entered = true; await driver.sendInteractive(.select, request: RemoteInputRequest()) }
        await waitUntil { entered }
        respondToPointerRequest(control)
        let pointer = LocalWebSocket.instances.last!
        await operation.value
        #expect(pointer.sent == ["type:button\nname:ENTER\n\n"])
        driver.disconnect()
    }

    @Test func lgRetainsEachOneShotUntilPointerHandshake() async {
        LocalWebSocket.delayedOpenPaths = ["/pointer"]
        defer { LocalWebSocket.delayedOpenPaths = [] }
        for (key, name) in [(RemoteKey.select, "ENTER"), (.back, "BACK"), (.home, "HOME")] {
            let (driver, _, pointer) = connectLG()
            #expect(!pointer.isReady)
            var entered = false
            let operation = Task { entered = true; await driver.sendInteractive(key, request: RemoteInputRequest()) }
            await waitUntil { entered }
            #expect(pointer.sent.isEmpty)
            pointer.completeHandshake()
            await operation.value
            #expect(pointer.sent == ["type:button\nname:\(name)\n\n"])
            driver.disconnect()
        }
    }

    @Test func lgBoundsRecoveryRequestsWhenPointerServiceDeclines() async {
        for key in [RemoteKey.home, .right] {
            LocalWebSocket.instances = []
            let driver = LGDriver(device: TVDevice(name: "Test LG", brand: .lg, host: "192.0.2.20", token: "test"))
            driver.connect()
            let control = LocalWebSocket.instances.last!
            control.onText?("{\"type\":\"registered\",\"id\":\"register_0\",\"payload\":{}}")
            let first = JSON.parse(control.sent.last!)!["id"] as! String
            control.onText?("{\"id\":\"\(first)\",\"payload\":{}}")
            let before = control.sent.count
            let request = RemoteInputRequest()
            var entered = false
            let operation = Task { entered = true; await driver.sendInteractive(key, request: request) }
            await waitUntil { entered && control.sent.count > before }
            var replied = Set<String>()
            let deadline = ContinuousClock.now + .milliseconds(160)
            while ContinuousClock.now < deadline {
                for text in control.sent.dropFirst(before) {
                    if let id = JSON.parse(text)?["id"] as? String, replied.insert(id).inserted {
                        control.onText?("{\"id\":\"\(id)\",\"payload\":{}}")
                    }
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            request.cancel()
            await operation.value
            #expect(control.sent.count == before + 1)
            #expect(driver.state == .connected) // Cancellation is quiet, not a timeout.
            driver.disconnect()
        }
    }

    @Test func lgMakesPointerTimeoutUnavailableAndPreservesCredentials() async {
        LocalWebSocket.delayedOpenPaths = ["/pointer"]
        defer { LocalWebSocket.delayedOpenPaths = [] }
        let (driver, control, pointer) = connectLG()
        await driver.sendInteractive(.home, request: RemoteInputRequest())
        #expect(driver.state == .idle) // No failed-address rediscovery for a pointer error.
        #expect(driver.device.token == "test")
        #expect(!control.isReady)
        #expect(!pointer.isReady)
        #expect(pointer.sent.isEmpty)
    }

    @Test func lgMissingPointerCreationTimesOutForDirection() async {
        LocalWebSocket.instances = []
        let driver = LGDriver(device: TVDevice(name: "Test LG", brand: .lg, host: "192.0.2.20", token: "test"))
        driver.connect()
        let control = LocalWebSocket.instances.last!
        control.onText?("{\"type\":\"registered\",\"id\":\"register_0\",\"payload\":{}}")
        let before = control.sent.count
        // No pointer descriptor arrives; direction-only input must still hit the bound.
        await driver.sendInteractive(.right, request: RemoteInputRequest())
        #expect(driver.state == .idle)
        #expect(driver.device.token == "test")
        #expect(!control.isReady)
        #expect(control.sent.count == before) // No duplicate acquisition requests.
        #expect(LocalWebSocket.instances.count == 1)
    }

    @Test func lgMissingPointerCancellationStaysQuietAndDoesNotReplayDirection() async {
        LocalWebSocket.instances = []
        let driver = LGDriver(device: TVDevice(name: "Test LG", brand: .lg, host: "192.0.2.20", token: "test"))
        driver.connect()
        let control = LocalWebSocket.instances.last!
        control.onText?("{\"type\":\"registered\",\"id\":\"register_0\",\"payload\":{}}")
        let before = control.sent.count
        let request = RemoteInputRequest()
        var entered = false
        let operation = Task { entered = true; await driver.sendInteractive(.right, request: request) }
        await waitUntil { entered }
        request.cancel() // Lift before the pointer descriptor or readiness deadline.
        await operation.value
        #expect(driver.state == .connected)
        #expect(driver.device.token == "test")
        #expect(control.sent.count == before)
        respondToPointerRequest(control)
        let pointer = LocalWebSocket.instances.last!
        #expect(pointer.sent.isEmpty)
        await driver.sendInteractive(.up, request: RemoteInputRequest())
        #expect(pointer.sent == ["type:button\nname:UP\n\n"])
        driver.disconnect()
    }

    @Test func lgDiscardsCancelledInputDuringHandshake() async {
        LocalWebSocket.delayedOpenPaths = ["/pointer"]
        defer { LocalWebSocket.delayedOpenPaths = [] }
        for key in [RemoteKey.select, .right] {
            let (driver, _, pointer) = connectLG()
            let request = RemoteInputRequest()
            var entered = false
            let operation = Task { entered = true; await driver.sendInteractive(key, request: request) }
            await waitUntil { entered }
            request.cancel() // Lifecycle stop for OK, ordinary lift for movement.
            pointer.completeHandshake()
            await operation.value
            #expect(pointer.sent.isEmpty)
            #expect(driver.state == .connected)
            driver.disconnect()
        }
    }

    @Test func lgDoesNotCarryOneShotIntoANewPrimarySession() async {
        LocalWebSocket.delayedOpenPaths = ["/pointer"]
        defer { LocalWebSocket.delayedOpenPaths = [] }
        let (driver, _, oldPointer) = connectLG()
        var entered = false
        let operation = Task { entered = true; await driver.sendInteractive(.home, request: RemoteInputRequest()) }
        await waitUntil { entered }
        driver.disconnect()
        driver.connect()
        let replacementControl = LocalWebSocket.instances.last!
        replacementControl.onText?("{\"type\":\"registered\",\"id\":\"register_0\",\"payload\":{}}")
        respondToPointerRequest(replacementControl)
        let replacementPointer = LocalWebSocket.instances.last!
        replacementPointer.completeHandshake()
        await operation.value
        #expect(oldPointer.sent.isEmpty)
        #expect(replacementPointer.sent.isEmpty)
        #expect(driver.state == .connected)
        driver.disconnect()
    }

    @Test func lgDoesNotRecoverOrSendCancelledInput() async {
        let (driver, control, pointer) = connectLG()
        pointer.peerClosed()
        let request = RemoteInputRequest()
        request.cancel()
        let before = control.sent.count
        await driver.sendInteractive(.back, request: request)
        #expect(control.sent.count == before)
        #expect(LocalWebSocket.instances.count == 2)
    }

    @Test func lgDoesNotPairOrReconnectFromDisconnectedInteractiveInput() async {
        let (driver, control, _) = connectLG()
        driver.disconnect()
        let before = control.sent.count
        await driver.sendInteractive(.home, request: RemoteInputRequest())
        #expect(control.sent.count == before)
        #expect(driver.state == .idle)
    }
}
