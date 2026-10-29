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
        #expect(CursorCommand.move(dx: 10000, dy: -10000).bounded == .move(dx: 768, dy: -768))
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
        await waitUntil { sent.count == 9 }
        #expect(sent[0] == .move(dx: 1, dy: 1))
        #expect(sent.dropFirst().allSatisfy { $0 == .move(dx: 96, dy: -96) })
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

    @Test func cursorSpeedIsLinearAndKeepsFineMovement() {
        #expect(CursorMotion.move(dx: 0.25, dy: 0, speed: 4) == .move(dx: 1, dy: 0))
        #expect(CursorMotion.move(dx: 2, dy: 0, speed: 16) == .move(dx: 32, dy: 0))
        #expect(CursorMotion.move(dx: 2, dy: 0, speed: 32) == .move(dx: 64, dy: 0))
        #expect(CursorMotion.move(dx: 2, dy: 0, speed: 96) == .move(dx: 192, dy: 0))
    }

    @Test func cursorSpeedIsBoundedAndInvalidInputIsIgnored() {
        #expect(CursorMotion.move(dx: 1, dy: -1, speed: 96) == CursorMotion.move(dx: 1, dy: -1, speed: 600))
        #expect(CursorMotion.move(dx: .nan, dy: 0, speed: 32) == nil)
        #expect(CursorMotion.move(dx: 1, dy: .infinity, speed: 32) == nil)
        #expect(CursorMotion.move(dx: 1, dy: 0, speed: .nan) == nil)
        #expect(CursorMotion.move(dx: 0, dy: 0, speed: 32) == nil)
    }

    @Test func scrollSurfacesShareDirectionAndCanBeReversed() {
        #expect(CursorMotion.scroll(dx: 0, dy: 18, reversed: false) == .scroll(dx: 0, dy: -1))
        #expect(CursorMotion.scroll(dx: 0, dy: 18, reversed: true) == .scroll(dx: 0, dy: 1))
        #expect(CursorMotion.scroll(dx: .infinity, dy: 0, reversed: false) == nil)
    }

    @Test func scrollStepsPreserveSlowDragsAndCancelOppositeJitter() {
        var scroll = CursorScrollAccumulator()
        for _ in 0..<100 {
            #expect(scroll.append(dx: 0.00001, dy: -0.00001) == nil)
            #expect(scroll.append(dx: -0.00001, dy: 0.00001) == nil)
        }
        #expect(scroll.append(dx: 0.25, dy: -0.5) == nil)
        #expect(scroll.append(dx: 0.25, dy: -0.5) == .scroll(dx: 0, dy: -1))
        #expect(scroll.append(dx: 0.75, dy: 0) == .scroll(dx: 1, dy: 0))
        #expect(scroll.append(dx: .nan, dy: 1) == nil)
        #expect(scroll.append(dx: 0.75, dy: 0) == .scroll(dx: 1, dy: 0))
        scroll.reset()
        #expect(scroll.append(dx: 0, dy: 0.5) == nil)
    }

    @Test func tinyScrollJitterHasNoPacketsHapticsOrActivity() async {
        var feedback: [RemoteInputRequest.Feedback] = []
        let sender = CursorSender(send: { _, request in feedback.append(request.feedback); return true })
        for _ in 0..<100 {
            sender.scroll(dx: 0, dy: 0.00001)
            sender.scroll(dx: 0, dy: -0.00001)
        }
        try? await Task.sleep(for: .milliseconds(60))
        #expect(feedback.isEmpty)
        #expect(sender.scrollActivity == 0)
        sender.stop()
    }

    @Test func aStationaryScrollHoldDoesNotRepeatFeedbackOrActivity() async {
        var sent: [CursorCommand] = []
        var feedback: [RemoteInputRequest.Feedback] = []
        let sender = CursorSender(send: { command, request in
            sent.append(command)
            feedback.append(request.feedback)
            return true
        })
        sender.scroll(dx: 0, dy: 0.5)
        sender.scroll(dx: 0, dy: 0.75)
        await waitUntil { sender.scrollActivity == 1 }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(sent == [.scroll(dx: 0, dy: 1)])
        #expect(feedback == [.firm])
        #expect(sender.scrollActivity == 1)
        sender.stop()
    }

    @Test func liftDropsPartialScrollStepsBetweenContacts() async {
        var sent: [CursorCommand] = []
        let sender = CursorSender(send: { command, _ in sent.append(command); return true })
        sender.scroll(dx: 0, dy: 0.75)
        sender.release()
        sender.scroll(dx: 0, dy: 0.5)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(sent.isEmpty)
        sender.scroll(dx: 0, dy: 0.5)
        await waitUntil { sender.scrollActivity == 1 }
        #expect(sent == [.scroll(dx: 0, dy: 1)])
        sender.stop()
    }

    @Test func failedScrollDropsPartialStepsAndDoesNotReportActivity() async {
        var ready = false
        var sent: [CursorCommand] = []
        let sender = CursorSender(send: { command, _ in sent.append(command); return ready })
        sender.scroll(dx: 0, dy: 1.75)
        await waitUntil { sender.unavailable }
        #expect(sender.scrollActivity == 0)
        ready = true
        sender.scroll(dx: 0, dy: 0.25)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(sent.count == 1)
        sender.scroll(dx: 0, dy: 0.75)
        await waitUntil { sender.scrollActivity == 1 }
        #expect(sent == [.scroll(dx: 0, dy: 1), .scroll(dx: 0, dy: 1)])
        sender.stop()
    }

    @Test func pointerMovementIsAlwaysSilent() {
        var policy = CursorFeedbackPolicy()
        #expect(policy.next(.move(dx: 1, dy: 0), time: 0) == .none)
        #expect(policy.next(.move(dx: 1, dy: 0), time: 0.1) == .none)
        #expect(policy.next(.move(dx: 1, dy: 0), time: 0.26) == .none)
        #expect(policy.next(.move(dx: 1, dy: 0), time: 0.3) == .none)
        policy.reset()
        #expect(policy.next(.move(dx: 1, dy: 0), time: 0.31) == .none)
    }

    @Test func scrollingHasTactileTicksAndButtonsHaveTheirOwnFeedback() {
        var policy = CursorFeedbackPolicy()
        #expect(policy.next(.scroll(dx: 0, dy: 1), time: 0) == .firm)
        #expect(policy.next(.scroll(dx: 0, dy: 1), time: 0.08) == .none)
        #expect(policy.next(.scroll(dx: 0, dy: 1), time: 0.13) == .soft)
        #expect(policy.next(.click, time: 0.14) == .firm)
        #expect(policy.next(.back, time: 0.15) == .firm)
        #expect(policy.next(.move(dx: 1, dy: 0), time: 0.16) == .none)
    }

    @Test func aFailedSendDoesNotConsumeTheFirstHapticPulse() async {
        var feedback: [RemoteInputRequest.Feedback] = []
        var ready = false
        let sender = CursorSender(send: { _, request in feedback.append(request.feedback); return ready })
        sender.scroll(dx: 0, dy: 1)
        await waitUntil { sender.unavailable }
        ready = true
        sender.scroll(dx: 0, dy: 1)
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
        #expect(feedback[0] == .none)
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
        sender.scroll(dx: 0, dy: 1)
        await waitUntil { resume != nil }
        clock = 10
        resume?.resume(returning: true)
        await waitUntil { firstReturned }
        clock = 10.02
        sender.scroll(dx: 0, dy: 1)
        await waitUntil { feedback.count == 2 }
        #expect(feedback[1] == .none)
        clock = 10.3
        sender.scroll(dx: 0, dy: 1)
        await waitUntil { feedback.count == 3 }
        #expect(feedback[2] == .soft)
        sender.stop()
    }

    @Test func largeMovementsAreSplitWithoutLosingDistanceOrDirection() async {
        var sent: [CursorCommand] = []
        var feedback: [RemoteInputRequest.Feedback] = []
        let sender = CursorSender(send: { command, request in
            sent.append(command)
            feedback.append(request.feedback)
            return true
        })
        sender.move(dx: 500, dy: -125)
        await waitUntil { sent.count == 6 }
        var x = 0.0, y = 0.0
        for command in sent {
            guard case let .move(dx, dy) = command else { Issue.record("Unexpected cursor command"); continue }
            #expect(abs(dx) <= 96.001 && abs(dy) <= 96.001)
            #expect(abs(dy + dx / 4) < 0.0001)
            x += dx; y += dy
        }
        #expect(abs(x - 500) < 0.0001 && abs(y + 125) < 0.0001)
        #expect(feedback.allSatisfy { $0 == .none })
        sender.stop()
    }

    @Test func anExistingGestureCallbackReadsTheLiveSpeedAndPersistsIt() async {
        var sent: [CursorCommand] = []
        var saved: [Double] = []
        let sender = CursorSender(send: { command, _ in sent.append(command); return true },
                                  speed: 4, saveSpeed: { saved.append($0) })
        let gesture = { sender.drag(dx: 2, dy: 0) }
        for speed in [4.0, 16, 32, 64, 96] {
            sender.setSpeed(speed)
            let start = sent.count
            gesture()
            let distance = {
                sent.dropFirst(start).reduce(0.0) { result, command in
                    if case let .move(dx, _) = command { return result + dx }
                    return result
                }
            }
            await waitUntil { distance() >= 2 * speed - 0.0001 }
            #expect(abs(distance() - 2 * speed) < 0.0001)
            #expect(sender.speed == speed)
        }
        #expect(saved == [16, 32, 64, 96])
        sender.stop()
    }

    @Test func changingSpeedDropsOldMovementBeforeApplyingTheNewGain() async {
        var sent: [CursorCommand] = []
        var active: RemoteInputRequest?
        var resume: CheckedContinuation<Bool, Never>?
        let sender = CursorSender(send: { command, request in
            sent.append(command)
            if sent.count == 1 {
                active = request
                return await withCheckedContinuation { resume = $0 }
            }
            return true
        })
        sender.move(dx: 500, dy: 0)
        await waitUntil { resume != nil }
        sender.setSpeed(64)
        #expect(active?.isCancelled == true)
        sender.drag(dx: 1, dy: 0)
        resume?.resume(returning: true)
        await waitUntil { sent.count == 2 }
        #expect(sent == [.move(dx: 96, dy: 0), .move(dx: 64, dy: 0)])
        sender.stop()
    }

    @Test func invalidSavedSpeedsAndSliderValuesAreClamped() {
        let sender = CursorSender(send: { _, _ in true }, speed: .nan)
        #expect(sender.speed == 12)
        sender.setSpeed(-100)
        #expect(sender.speed == 4)
        sender.setSpeed(1000)
        #expect(sender.speed == 96)
        sender.stop()
    }

    @Test func speedDefaultsToTwelveAndPreservesAnExplicitSavedChoice() {
        let defaults = CursorSender(send: { _, _ in true })
        let saved = CursorSender(send: { _, _ in true }, speed: 16)
        #expect(defaults.speed == 12)
        #expect(saved.speed == 16)
        defaults.stop(); saved.stop()
    }
}
