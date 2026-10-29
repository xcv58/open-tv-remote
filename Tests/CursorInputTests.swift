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
        #expect(CursorCommand.move(dx: 10000, dy: -10000).bounded == .move(dx: 1024, dy: -1024))
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
        #expect(sent == [.move(dx: 1, dy: 1), .move(dx: 1024, dy: -1024)])
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

    @Test func cursorSpeedHasMoreRangeWhileSlowMovementsKeepPrecision() {
        #expect(CursorMotion.move(dx: 0.25, dy: 0, velocity: 20, speed: 0.5) == .move(dx: 0.5, dy: 0))
        #expect(CursorMotion.move(dx: 10, dy: 0, velocity: 20, speed: 3) == .move(dx: 120, dy: 0))
        #expect(CursorMotion.move(dx: 10, dy: 0, velocity: 700, speed: 3) == .move(dx: 240, dy: 0))
        #expect(CursorMotion.move(dx: 10, dy: 0, velocity: 700, speed: 6) == .move(dx: 480, dy: 0))
    }

    @Test func cursorAccelerationIsBoundedAndInvalidInputIsIgnored() {
        #expect(CursorMotion.move(dx: 1, dy: -1, velocity: 700, speed: 6) ==
                CursorMotion.move(dx: 1, dy: -1, velocity: 100000, speed: 600))
        #expect(CursorMotion.move(dx: .nan, dy: 0, velocity: 20, speed: 1) == nil)
        #expect(CursorMotion.move(dx: 1, dy: 0, velocity: .infinity, speed: 1) == nil)
        #expect(CursorMotion.move(dx: 1, dy: 0, velocity: 20, speed: .nan) == nil)
        #expect(CursorMotion.move(dx: 0, dy: 0, velocity: 20, speed: 1) == nil)
    }

    @Test func scrollSurfacesShareDirectionAndCanBeReversed() {
        #expect(CursorMotion.scroll(dx: 0, dy: 18, reversed: false) == .scroll(dx: 0, dy: -1))
        #expect(CursorMotion.scroll(dx: 0, dy: 18, reversed: true) == .scroll(dx: 0, dy: 1))
        #expect(CursorMotion.scroll(dx: .infinity, dy: 0, reversed: false) == nil)
    }

    @Test func feedbackHasAFirmStartThenRateLimitedMotionPulses() {
        var policy = CursorFeedbackPolicy()
        #expect(policy.next(.move(dx: 1, dy: 0), time: 0) == .firm)
        #expect(policy.next(.move(dx: 1, dy: 0), time: 0.1) == .none)
        #expect(policy.next(.move(dx: 1, dy: 0), time: 0.26) == .soft)
        #expect(policy.next(.move(dx: 1, dy: 0), time: 0.3) == .none)
        policy.reset()
        #expect(policy.next(.move(dx: 1, dy: 0), time: 0.31) == .firm)
    }

    @Test func scrollingHasTactileTicksAndButtonsHaveTheirOwnFeedback() {
        var policy = CursorFeedbackPolicy()
        #expect(policy.next(.scroll(dx: 0, dy: 1), time: 0) == .firm)
        #expect(policy.next(.scroll(dx: 0, dy: 1), time: 0.08) == .none)
        #expect(policy.next(.scroll(dx: 0, dy: 1), time: 0.13) == .soft)
        #expect(policy.next(.click, time: 0.14) == .firm)
        #expect(policy.next(.back, time: 0.15) == .firm)
        #expect(policy.next(.move(dx: 1, dy: 0), time: 0.16) == .firm)
    }

    @Test func aFailedSendDoesNotConsumeTheFirstHapticPulse() async {
        var feedback: [RemoteInputRequest.Feedback] = []
        var ready = false
        let sender = CursorSender(send: { _, request in feedback.append(request.feedback); return ready })
        sender.move(dx: 1, dy: 0)
        await waitUntil { sender.unavailable }
        ready = true
        sender.move(dx: 1, dy: 0)
        await waitUntil { feedback.count == 2 }
        #expect(feedback[0] == .firm)
        #expect(feedback[1] == .firm)
        sender.stop()
    }

    @Test func aStalledSendDoesNotGenerateAHapticHeartbeat() async {
        var feedback: [RemoteInputRequest.Feedback] = []
        var resume: CheckedContinuation<Bool, Never>?
        let sender = CursorSender(send: { _, request in
            feedback.append(request.feedback)
            return await withCheckedContinuation { resume = $0 }
        })
        sender.move(dx: 1, dy: 0)
        await waitUntil { resume != nil }
        for _ in 0..<100 { sender.move(dx: 1, dy: 0) }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(feedback.count == 1)
        sender.stop()
        resume?.resume(returning: false)
    }

    @Test func hapticSpacingStartsAtDeliveryAfterASlowSend() async {
        var clock: TimeInterval = 0
        var feedback: [RemoteInputRequest.Feedback] = []
        var resume: CheckedContinuation<Bool, Never>?
        var firstReturned = false
        let sender = CursorSender(send: { _, request in
            feedback.append(request.feedback)
            if feedback.count == 1 {
                let sent = await withCheckedContinuation { resume = $0 }
                firstReturned = true
                return sent
            }
            return true
        }, now: { clock })
        sender.move(dx: 1, dy: 0)
        await waitUntil { resume != nil }
        clock = 10
        resume?.resume(returning: true)
        await waitUntil { firstReturned }
        clock = 10.02
        sender.move(dx: 1, dy: 0)
        await waitUntil { feedback.count == 2 }
        #expect(feedback[1] == .none)
        clock = 10.3
        sender.move(dx: 1, dy: 0)
        await waitUntil { feedback.count == 3 }
        #expect(feedback[2] == .soft)
        sender.stop()
    }
}
