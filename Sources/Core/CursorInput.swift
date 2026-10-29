import Foundation
import Observation

enum CursorCommand: Equatable {
    static let maximumPacketDelta = 96.0
    static let pendingMovementLimit = 768.0
    case move(dx: Double, dy: Double)
    case scroll(dx: Double, dy: Double)
    case click, back, home

    var isContinuous: Bool {
        switch self { case .move, .scroll: true; default: false }
    }

    /// Bound a slow connection's accumulated movement and reject invalid sensor/gesture values.
    var bounded: CursorCommand? {
        switch self {
        case .move(let dx, let dy): return Self.delta(dx, dy, limit: Self.pendingMovementLimit, scroll: false)
        case .scroll(let dx, let dy): return Self.delta(dx, dy, limit: 12, scroll: true)
        default: return self
        }
    }

    private static func delta(_ dx: Double, _ dy: Double, limit: Double, scroll: Bool) -> CursorCommand? {
        guard dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { return nil }
        let x = min(limit, max(-limit, dx)), y = min(limit, max(-limit, dy))
        return scroll ? .scroll(dx: x, dy: y) : .move(dx: x, dy: y)
    }

    func adding(_ next: CursorCommand) -> CursorCommand? {
        switch (self, next) {
        case let (.move(x, y), .move(nx, ny)): return CursorCommand.move(dx: x + nx, dy: y + ny).bounded
        case let (.scroll(x, y), .scroll(nx, ny)): return CursorCommand.scroll(dx: x + nx, dy: y + ny).bounded
        default: return nil
        }
    }

    /// Keep wire movements small and retain the rest until sent or the gesture ends.
    /// The pending budget is separate from the per-packet compatibility size.
    var nextPacket: (command: CursorCommand, remainder: CursorCommand?) {
        guard case let .move(dx, dy) = self else { return (self, nil) }
        let largest = max(abs(dx), abs(dy))
        guard largest > Self.maximumPacketDelta else { return (self, nil) }
        let fraction = Self.maximumPacketDelta / largest
        let x = dx * fraction, y = dy * fraction
        let remainingX = dx - x, remainingY = dy - y
        let remainder: CursorCommand? = max(abs(remainingX), abs(remainingY)) >= 0.0005
            ? .move(dx: remainingX, dy: remainingY) : nil
        return (.move(dx: x, dy: y), remainder)
    }
}

enum CursorMotion {
    static let speedRange = 4.0...96.0
    static let defaultSpeed = 12.0

    static func validatedSpeed(_ value: Double) -> Double {
        value.isFinite ? min(speedRange.upperBound, max(speedRange.lowerBound, value)) : defaultSpeed
    }

    /// One predictable linear gain: slider changes never depend on swipe velocity.
    static func move(dx: Double, dy: Double, speed: Double) -> CursorCommand? {
        guard dx.isFinite, dy.isFinite, speed.isFinite else { return nil }
        let gain = validatedSpeed(speed)
        return CursorCommand.move(dx: dx * gain, dy: dy * gain).bounded
    }

    static func scroll(dx: Double, dy: Double, reversed: Bool) -> CursorCommand? {
        let direction = reversed ? 1.0 : -1.0
        return CursorCommand.scroll(dx: dx * direction / 18, dy: dy * direction / 18).bounded
    }
}

/// Preserve slow drags, but only send complete wheel steps that can earn feedback.
struct CursorScrollAccumulator {
    private var x = 0.0
    private var y = 0.0

    mutating func append(dx: Double, dy: Double) -> CursorCommand? {
        guard case let .scroll(dx, dy)? = CursorCommand.scroll(dx: dx, dy: dy).bounded else { return nil }
        x += dx
        y += dy
        let wholeX = x.rounded(.towardZero), wholeY = y.rounded(.towardZero)
        x -= wholeX
        y -= wholeY
        return CursorCommand.scroll(dx: wholeX, dy: wholeY).bounded
    }

    mutating func reset() { x = 0; y = 0 }
}

/// Feedback follows dispatched input, with no timer that can buzz during a stalled send.
struct CursorFeedbackPolicy {
    private var lastPulse: TimeInterval?

    mutating func next(_ command: CursorCommand, time: TimeInterval) -> RemoteInputRequest.Feedback {
        guard time.isFinite else { return .none }
        if case .move = command { return .none }
        guard case .scroll = command else { return .firm }
        guard let previous = lastPulse else {
            lastPulse = time
            return .firm
        }
        guard time - previous >= 0.12 else { return .none }
        lastPulse = time
        return .soft
    }

    mutating func reset() { lastPulse = nil }

    mutating func delivered(at time: TimeInterval) {
        guard time.isFinite, lastPulse != nil else { return }
        lastPulse = time
    }
}

/// A single transport worker, with coalesced movement rather than a growing drag tail.
/// Lift cancels movement; lifecycle changes also cancel accepted clicks and buttons.
@MainActor
@Observable
final class CursorSender {
    private(set) var unavailable = false
    private(set) var speed: Double
    private(set) var scrollActivity = 0
    @ObservationIgnored private let send: (CursorCommand, RemoteInputRequest) async -> Bool
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private let saveSpeed: (Double) -> Void
    @ObservationIgnored private var feedback = CursorFeedbackPolicy()
    @ObservationIgnored private var scrollAccumulator = CursorScrollAccumulator()
    @ObservationIgnored private var pending: [CursorCommand] = []
    @ObservationIgnored private var active: (command: CursorCommand, request: RemoteInputRequest)?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var pause: Task<Void, Error>?
    @ObservationIgnored private var generation = 0

    init(send: @escaping (CursorCommand, RemoteInputRequest) async -> Bool,
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         speed: Double = CursorMotion.defaultSpeed, saveSpeed: @escaping (Double) -> Void = { _ in }) {
        self.send = send
        self.sleep = sleep
        self.now = now
        self.speed = CursorMotion.validatedSpeed(speed)
        self.saveSpeed = saveSpeed
    }

    func setSpeed(_ value: Double) {
        let value = CursorMotion.validatedSpeed(value)
        guard value != speed else { return }
        release()
        speed = value
        saveSpeed(value)
    }

    func drag(dx: Double, dy: Double) {
        if case let .move(x, y)? = CursorMotion.move(dx: dx, dy: dy, speed: speed) {
            move(dx: x, dy: y)
        }
    }

    func move(dx: Double, dy: Double) { enqueue(.move(dx: dx, dy: dy)) }
    func scroll(dx: Double, dy: Double) {
        if let command = scrollAccumulator.append(dx: dx, dy: dy) { enqueue(command) }
    }

    func press(_ command: CursorCommand) {
        guard !command.isContinuous else { return }
        release()
        enqueue(command)
    }

    func release() {
        generation += 1
        pending.removeAll { $0.isContinuous }
        if active?.command.isContinuous == true { active?.request.cancel() }
        pause?.cancel()
        feedback.reset()
        scrollAccumulator.reset()
    }

    func stop() {
        release()
        active?.request.cancel()
        pending.removeAll()
    }

    private func enqueue(_ command: CursorCommand) {
        guard let command = command.bounded else { return }
        if command.isContinuous, let previous = pending.last {
            switch (previous, command) {
            case (.move, .move), (.scroll, .scroll):
                pending.removeLast()
                if let combined = previous.adding(command) { pending.append(combined) }
            default:
                guard pending.count < 16 else { return }
                pending.append(command)
            }
        } else {
            guard pending.count < 16 else { return }
            pending.append(command)
        }
        guard worker == nil, !pending.isEmpty else { return }
        worker = Task { @MainActor [weak self] in await self?.run() }
    }

    private func run() async {
        defer { worker = nil }
        while !pending.isEmpty {
            if pending[0].isContinuous {
                let token = generation, sleep = self.sleep
                let delay: Duration
                if case .move = pending[0] { delay = .milliseconds(8) }
                else { delay = .milliseconds(25) }
                let wait = Task { @MainActor in try await sleep(delay) }
                pause = wait
                do { try await wait.value } catch { }
                pause = nil
                guard token == generation else { continue }
            }
            guard !pending.isEmpty else { continue }
            let packet = pending.removeFirst().nextPacket, token = generation
            let command = packet.command
            if let remainder = packet.remainder { pending.insert(remainder, at: 0) }
            var nextFeedback = feedback
            let request = RemoteInputRequest(feedback: nextFeedback.next(command, time: now()))
            active = (command, request)
            let sent = await send(command, request)
            active = nil
            if !request.isCancelled, token == generation {
                unavailable = !sent
                if sent {
                    if case .scroll = command { scrollActivity += 1 }
                    if request.feedback != .none { nextFeedback.delivered(at: now()) }
                    feedback = nextFeedback
                }
                if !sent {
                    pending.removeAll { $0.isContinuous }
                    scrollAccumulator.reset()
                }
            }
        }
    }
}
