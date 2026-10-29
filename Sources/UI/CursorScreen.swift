import SwiftUI
#if os(iOS)
import UIKit
#endif

struct CursorScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CursorControls(tvName: model.current?.name ?? "No TV selected",
                       enabled: model.supportsCursor && model.state == .connected,
                       sessionID: model.currentID, close: { dismiss() }) { command, request in
            let sent = await model.sendCursor(command, request: request)
            if sent, !command.isContinuous { Haptics.tick() }
            return sent
        }
    }
}

private struct CursorControls: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("cursor.sensitivity.v1") private var sensitivity = 1.5
    @State private var sender: CursorSender
    let tvName: String
    let enabled: Bool
    let sessionID: String?
    let close: () -> Void

    init(tvName: String, enabled: Bool, sessionID: String?, close: @escaping () -> Void,
         send: @escaping (CursorCommand, RemoteInputRequest) async -> Bool) {
        self.tvName = tvName
        self.enabled = enabled
        self.sessionID = sessionID
        self.close = close
        _sender = State(initialValue: CursorSender(send: send))
    }

    var body: some View {
        VStack(spacing: 16) {
            header
            VStack(spacing: 5) {
                Text(enabled ? "Drag to move · Tap to click" : "Connect to your LG TV first")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Text(status)
                    .font(.system(size: 13))
                    .foregroundStyle(sender.unavailable ? Theme.power : Theme.secondary)
                    .multilineTextAlignment(.center)
            }
            touchpad
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 180)
            VStack(spacing: 6) {
                HStack {
                    Text("Cursor speed")
                    Spacer()
                    Text(sensitivity, format: .number.precision(.fractionLength(1)))
                        .monospacedDigit()
                }
                .font(.system(size: 13, weight: .medium))
                Slider(value: $sensitivity, in: 0.5...3, step: 0.25)
                    .accessibilityLabel("Cursor speed")
            }
            HStack(spacing: 12) {
                action("Scroll up", symbol: "arrow.up", command: .scroll(dx: 0, dy: -1))
                action("Scroll down", symbol: "arrow.down", command: .scroll(dx: 0, dy: 1))
            }
            HStack(spacing: 12) {
                action("Back", symbol: "arrow.uturn.backward", command: .back)
                action("Click", symbol: "cursorarrow.click", command: .click)
            }
        }
        .foregroundStyle(Theme.label)
        .padding(20)
        .frame(maxWidth: 600, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .onChange(of: enabled) { _, _ in sender.stop() }
        .onChange(of: sessionID) { _, _ in sender.stop() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { sender.stop() } }
        .onDisappear { sender.stop() }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 640)
        #endif
    }

    private var status: String {
        if !enabled { return "Close cursor mode to choose or reconnect to a TV." }
        if sender.unavailable { return "Cursor not ready. Try again, or close to reconnect." }
        #if os(iOS)
        return "Two fingers to scroll · Lift to stop"
        #else
        return "Drag to move · Use the scroll buttons below"
        #endif
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button { sender.stop(); close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Theme.keyTop))
            }
            .buttonStyle(.plain).accessibilityLabel("Close cursor mode")
            VStack(alignment: .leading, spacing: 3) {
                Text("LG Cursor").font(.system(size: 24, weight: .bold, design: .rounded))
                Text(tvName).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { press(.home) } label: {
                Image(systemName: "house")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Theme.keyTop))
            }
            .buttonStyle(.plain).disabled(!enabled).accessibilityLabel("Home")
        }
    }

    private var touchpad: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30).fill(Theme.well)
            RoundedRectangle(cornerRadius: 30).strokeBorder(Theme.accent.opacity(0.2))
            VStack(spacing: 12) {
                Image(systemName: "hand.draw").font(.system(size: 48, weight: .light))
                Text("Look at your TV").font(.system(size: 16, weight: .medium, design: .rounded))
            }
            .foregroundStyle(Theme.secondary.opacity(0.6))
            .allowsHitTesting(false)
            #if os(iOS)
            CursorTouchpad(enabled: enabled && scenePhase == .active,
                           move: { dx, dy in move(dx, dy) },
                           scroll: { dx, dy in
                               guard enabled, scenePhase == .active else { return }
                               sender.scroll(dx: -dx / 28, dy: -dy / 28)
                           }, click: { press(.click) }, release: { sender.release() })
                .id(sessionID)
            #else
            MacCursorTouchpad(enabled: enabled && scenePhase == .active,
                              move: { dx, dy in move(dx, dy) },
                              click: { press(.click) }, release: { sender.release() })
                .id(sessionID)
            #endif
        }
        .clipShape(RoundedRectangle(cornerRadius: 30))
        .accessibilityIdentifier("lgCursorTouchpad")
    }

    private func action(_ title: String, symbol: String, command: CursorCommand) -> some View {
        Button {
            if command.isContinuous {
                guard enabled, scenePhase == .active else { return }
                sender.release()
                if case let .scroll(dx, dy) = command { sender.scroll(dx: dx, dy: dy) }
            } else { press(command) }
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(RoundedRectangle(cornerRadius: 18).fill(Theme.keyTop))
        }
        .buttonStyle(.plain).disabled(!enabled)
    }

    private func move(_ dx: Double, _ dy: Double) {
        guard enabled, scenePhase == .active else { return }
        sender.move(dx: dx * min(3, max(0.5, sensitivity)), dy: dy * min(3, max(0.5, sensitivity)))
    }

    private func press(_ command: CursorCommand) {
        guard enabled, scenePhase == .active else { return }
        sender.press(command)
    }
}

#if os(iOS)
/// Native recognizers distinguish pointer movement, two-finger scrolling and a tap.
/// A cancelled/scrolling gesture must never turn into a pointer click.
private struct CursorTouchpad: UIViewRepresentable {
    let enabled: Bool
    let move: (Double, Double) -> Void
    let scroll: (Double, Double) -> Void
    let click: () -> Void
    let release: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isMultipleTouchEnabled = true
        view.backgroundColor = .clear
        let move = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.move(_:)))
        move.minimumNumberOfTouches = 1
        move.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.scroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.click(_:)))
        tap.require(toFail: move)
        tap.require(toFail: scroll)
        for recognizer in [move, scroll, tap] { view.addGestureRecognizer(recognizer) }
        view.isAccessibilityElement = true
        view.accessibilityLabel = "LG cursor touchpad"
        view.accessibilityHint = "Drag one finger to move the TV pointer, tap to click, or drag two fingers to scroll."
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        view.isUserInteractionEnabled = enabled
        for recognizer in view.gestureRecognizers ?? [] where recognizer.isEnabled != enabled {
            recognizer.isEnabled = enabled
        }
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.parent.release() }

    final class Coordinator: NSObject {
        var parent: CursorTouchpad
        init(_ parent: CursorTouchpad) { self.parent = parent }

        @objc func move(_ pan: UIPanGestureRecognizer) { handle(pan, scrolling: false) }
        @objc func scroll(_ pan: UIPanGestureRecognizer) { handle(pan, scrolling: true) }
        @objc func click(_ tap: UITapGestureRecognizer) {
            if parent.enabled, tap.state == .ended { parent.click() }
        }

        private func handle(_ pan: UIPanGestureRecognizer, scrolling: Bool) {
            guard parent.enabled else { parent.release(); return }
            switch pan.state {
            case .began, .changed:
                if pan.state == .began { parent.release() }
                let delta = pan.translation(in: pan.view)
                pan.setTranslation(.zero, in: pan.view)
                if scrolling { parent.scroll(Double(delta.x), Double(delta.y)) }
                else { parent.move(Double(delta.x), Double(delta.y)) }
            case .ended, .cancelled, .failed: parent.release()
            default: break
            }
        }
    }
}
#else
private struct MacCursorTouchpad: View {
    let enabled: Bool
    let move: (Double, Double) -> Void
    let click: () -> Void
    let release: () -> Void
    @State private var previous: CGSize = .zero
    @State private var dragging = false
    @State private var ignoreUntilLift = false

    var body: some View {
        Color.clear.contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 6)
                .onChanged { value in
                    dragging = true
                    guard enabled, !ignoreUntilLift else { return }
                    move(Double(value.translation.width - previous.width), Double(value.translation.height - previous.height))
                    previous = value.translation
                }
                .onEnded { _ in
                    previous = .zero
                    dragging = false
                    ignoreUntilLift = false
                    release()
                }
                .exclusively(before: TapGesture().onEnded { if enabled { click() } }))
            .onChange(of: enabled) { _, _ in
                ignoreUntilLift = dragging
                previous = .zero
                release()
            }
            .accessibilityLabel("LG cursor touchpad")
    }
}
#endif

#Preview("LG cursor") {
    CursorControls(tvName: "Living Room LG", enabled: true, sessionID: "preview", close: {}) { _, _ in true }
        .frame(width: 390, height: 844)
}
