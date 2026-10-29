import Foundation
import Testing
@testable import JoystickCore

@Suite("Cursor coalescing and cancellation", .serialized)
@MainActor
struct CursorInputTests {
    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(condition())
    }

    @Test func invalidAndZeroDeltasAreIgnoredAndLargeDeltasAreBounded() {
        #expect(CursorCommand.move(dx: .nan, dy: 1).bounded == nil)
        #expect(CursorCommand.scroll(dx: 1, dy: .infinity).bounded == nil)
        #expect(CursorCommand.move(dx: 0, dy: 0).bounded == nil)
        #expect(CursorCommand.move(dx: 10000, dy: -10000).bounded == .move(dx: 240, dy: -240))
        #expect(CursorCommand.scroll(dx: 10000, dy: -10000).bounded == .scroll(dx: 12, dy: -12))
    }

    @Test func shortDragDeltasAccumulateIntoOnePacket() async {
        var sent: [CursorCommand] = []
        let sender = CursorSender(send: { command, _ in sent.append(command); return true })
        for _ in 0..<10 { sender.move(dx: 0.5, dy: -0.25) }
        await waitUntil { sent.count == 1 }
        #expect(sent == [.move(dx: 5, dy: -2.5)])
        sender.stop()
    }

    @Test func opposingMovesCancelBeforeDispatch() async {
        var sent: [CursorCommand] = []
        let sender = CursorSender(send: { command, _ in sent.append(command); return true })
        sender.move(dx: 10, dy: 5)
        sender.move(dx: -10, dy: -5)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(sent.isEmpty)
        sender.stop()
    }

    @Test func liftDropsMovementBeforeTheThrottleWindowCloses() async {
        var sent: [CursorCommand] = []
        let sender = CursorSender(send: { command, _ in sent.append(command); return true })
        sender.move(dx: 100, dy: 50)
        sender.release()
        try? await Task.sleep(for: .milliseconds(60))
        #expect(sent.isEmpty)
        sender.stop()
    }

    @Test func aSlowTransportHasOnlyOneBoundedPendingMovement() async {
        var sent: [CursorCommand] = []
        var resume: CheckedContinuation<Bool, Never>?
        let sender = CursorSender(send: { command, _ in
            sent.append(command)
            if sent.count == 1 { return await withCheckedContinuation { resume = $0 } }
            return true
        })
        sender.move(dx: 1, dy: 1)
        await waitUntil { resume != nil }
        for _ in 0..<1000 { sender.move(dx: 5, dy: -5) }
        #expect(sent.count == 1)
        resume?.resume(returning: true)
        await waitUntil { sent.count == 2 }
        #expect(sent == [.move(dx: 1, dy: 1), .move(dx: 240, dy: -240)])
        sender.stop()
    }

    @Test func liftCancelsTheActiveDragAndItsTailButPreservesAnAcceptedClick() async {
        var sent: [CursorCommand] = []
        var active: RemoteInputRequest?
        var resume: CheckedContinuation<Bool, Never>?
        let sender = CursorSender(send: { command, request in
            sent.append(command)
            if command.isContinuous {
                active = request
                return await withCheckedContinuation { resume = $0 }
            }
            return true
        })
        sender.move(dx: 10, dy: 0)
        await waitUntil { resume != nil }
        sender.move(dx: 200, dy: 0)
        sender.press(.click)
        sender.release()
        #expect(active?.isCancelled == true)
        resume?.resume(returning: false)
        await waitUntil { sent.count == 2 }
        #expect(sent == [.move(dx: 10, dy: 0), .click])
        sender.stop()
    }

    @Test func stopInvalidatesClicksAndButtonsAsWellAsMovement() async {
        var sent: [CursorCommand] = []
        var active: RemoteInputRequest?
        var resume: CheckedContinuation<Bool, Never>?
        let sender = CursorSender(send: { command, request in
            sent.append(command)
            active = request
            return await withCheckedContinuation { resume = $0 }
        })
        sender.press(.click)
        await waitUntil { resume != nil }
        sender.press(.home)
        sender.move(dx: 1, dy: 0)
        sender.stop()
        #expect(active?.isCancelled == true)
        resume?.resume(returning: true)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(sent == [.click])
    }

    @Test func deliberateButtonsKeepTheirOrder() async {
        var sent: [CursorCommand] = []
        let sender = CursorSender(send: { command, _ in sent.append(command); return true })
        sender.press(.click)
        sender.press(.back)
        sender.press(.home)
        await waitUntil { sent.count == 3 }
        #expect(sent == [.click, .back, .home])
        sender.stop()
    }

    @Test func anUnavailableTransportDoesNotReplayMotionAndCanRecoverOnNewInput() async {
        var sent: [CursorCommand] = []
        var ready = false
        let sender = CursorSender(send: { command, _ in sent.append(command); return ready })
        sender.move(dx: 5, dy: 0)
        await waitUntil { sender.unavailable }
        ready = true
        try? await Task.sleep(for: .milliseconds(60))
        #expect(sent.count == 1)
        sender.move(dx: 2, dy: 0)
        await waitUntil { sent.count == 2 }
        #expect(!sender.unavailable)
        #expect(sent == [.move(dx: 5, dy: 0), .move(dx: 2, dy: 0)])
        sender.stop()
    }

    @Test func scrollingDoesNotBecomeAClickAndLiftStopsIt() async {
        var sent: [CursorCommand] = []
        let sender = CursorSender(send: { command, _ in sent.append(command); return true })
        sender.scroll(dx: 0, dy: 1)
        sender.scroll(dx: 0, dy: 1)
        await waitUntil { sent.count == 1 }
        sender.release()
        #expect(sent == [.scroll(dx: 0, dy: 2)])
        sender.stop()
    }
}
