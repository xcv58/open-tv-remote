import Foundation
import Observation

enum CursorCommand: Equatable {
    case move(dx: Double, dy: Double)
    case scroll(dx: Double, dy: Double)
    case click, back, home

    var isContinuous: Bool {
        switch self { case .move, .scroll: true; default: false }
    }

    /// Bound a slow connection's accumulated movement and reject invalid sensor/gesture values.
    var bounded: CursorCommand? {
        switch self {
        case .move(let dx, let dy): return Self.delta(dx, dy, limit: 240, scroll: false)
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
}

/// A single transport worker, with coalesced movement rather than a growing drag tail.
/// Lift cancels movement; lifecycle changes also cancel accepted clicks and buttons.
@MainActor
@Observable
final class CursorSender {
    private(set) var unavailable = false
    @ObservationIgnored private let send: (CursorCommand, RemoteInputRequest) async -> Bool
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private var pending: [CursorCommand] = []
    @ObservationIgnored private var active: (command: CursorCommand, request: RemoteInputRequest)?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var pause: Task<Void, Error>?
    @ObservationIgnored private var generation = 0

    init(send: @escaping (CursorCommand, RemoteInputRequest) async -> Bool,
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.send = send
        self.sleep = sleep
    }

    func move(dx: Double, dy: Double) { enqueue(.move(dx: dx, dy: dy)) }
    func scroll(dx: Double, dy: Double) { enqueue(.scroll(dx: dx, dy: dy)) }

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
                let wait = Task { @MainActor in try await sleep(.milliseconds(25)) }
                pause = wait
                do { try await wait.value } catch { }
                pause = nil
                guard token == generation else { continue }
            }
            guard !pending.isEmpty else { continue }
            let command = pending.removeFirst(), token = generation
            let request = RemoteInputRequest(feedback: .none)
            active = (command, request)
            let sent = await send(command, request)
            active = nil
            if !request.isCancelled, token == generation {
                unavailable = !sent
                if !sent { pending.removeAll { $0.isContinuous } }
            }
        }
    }
}
