import Foundation

/// LG webOS TVs: SSAP over WebSocket (wss://:3001 on current firmware, ws://:3000 on older).
/// Registration shows an Accept prompt on the TV once; afterwards we reuse the client key.
/// Navigation buttons go over a second "pointer input" socket the TV hands us.
@MainActor
final class LGDriver: TVDriver {
    private(set) var device: TVDevice
    weak var delegate: TVDriverDelegate?
    private(set) var state: ConnectionState = .idle {
        didSet { if state != oldValue { delegate?.driver(self, didChangeState: state) } }
    }

    private var socket: LocalWebSocket?
    private var pointer: LocalWebSocket?
    private var nextID = 1
    private var callbacks: [String: ([String: Any]) -> Void] = [:]
    private var playing = true
    /// Presses made while (re)connecting or before the pointer socket is up.
    private var pendingKeys: [RemoteKey] = []
    private var pendingLaunch: TVApp?
    private var pendingButtons: [String] = []
    private var requestingPointer = false
    private var pointerRequestID: String?
    private var pointerGeneration = 0
    private var pointerAcquisitionStarted: ContinuousClock.Instant?

    init(device: TVDevice) {
        self.device = device
    }

    func connect() {
        guard device.token != nil else {
            state = .unpaired
            return
        }
        open(secure: true, prompting: false)
    }

    func pair() { open(secure: true, prompting: true) }
    func submitPairingCode(_ code: String) {}

    func disconnect() {
        socket?.close()
        invalidatePointerChannel()
        socket = nil
        pointer = nil
        callbacks = [:]
        pendingLaunch = nil
        pendingKeys = []
        pendingButtons = []
        requestingPointer = false
        state = .idle
    }

    private func open(secure: Bool, prompting: Bool) {
        socket?.close()
        invalidatePointerChannel()
        let url = URL(string: secure ? "wss://\(device.host):3001" : "ws://\(device.host):3000")!
        let ws = LocalWebSocket(url: url)
        state = .connecting
        var opened = false
        ws.onOpen = { [weak self] in
            opened = true
            self?.register(prompting: prompting)
        }
        ws.onText = { [weak self] text in
            guard let self, let json = JSON.parse(text) else { return }
            if (json["id"] as? String) == "register_0" {
                self.handleRegistration(json)
            } else if let id = json["id"] as? String, let callback = self.callbacks.removeValue(forKey: id) {
                callback(json["payload"] as? [String: Any] ?? [:])
            }
        }
        ws.onClose = { [weak self] _ in
            guard let self else { return }
            self.socket = nil
            if !opened && secure {
                // Older firmware only speaks plain ws on 3000.
                self.open(secure: false, prompting: prompting)
            } else if self.state == .connected {
                self.state = .idle
            } else if case .pairing = self.state {
                self.state = .failed("The TV didn't accept the connection.")
            } else {
                self.state = .failed("Couldn't reach the TV. Is it on and on the same Wi-Fi?")
            }
        }
        socket = ws
        ws.start()
    }

    private func register(prompting: Bool) {
        var payload: [String: Any] = [
            "forcePairing": false,
            "pairingType": "PROMPT",
            "manifest": [
                "appVersion": "1.1",
                "manifestVersion": 1,
                "permissions": Self.permissions,
            ],
        ]
        if let key = device.token { payload["client-key"] = key }
        else if !prompting {
            // Never trigger the TV prompt unless the user asked to pair.
            socket?.close()
            state = .unpaired
            return
        }
        socket?.send(json: ["type": "register", "id": "register_0", "payload": payload])
    }

    @discardableResult
    private func handleRegistration(_ json: [String: Any]) -> Bool {
        let payload = json["payload"] as? [String: Any]
        switch json["type"] as? String {
        case "response":
            if (payload?["pairingType"] as? String) == "PROMPT" { state = .pairing(.acceptOnTV) }
            return false
        case "registered":
            if let key = payload?["client-key"] as? String, key != device.token {
                device.token = key
                delegate?.driver(self, didUpdateDevice: device)
            }
            state = .connected
            openPointerSocket()
            let queued = pendingKeys
            pendingKeys = []
            queued.forEach(send)
            if let app = pendingLaunch {
                pendingLaunch = nil
                launch(app)
            }
            return true
        case "error":
            if device.token != nil {
                device.token = nil
                delegate?.driver(self, didUpdateDevice: device)
            }
            socket?.close()
            socket = nil
            state = .failed("The TV rejected the connection. Try pairing again.")
            return false
        default:
            return false
        }
    }

    @discardableResult
    private func request(_ uri: String, _ payload: [String: Any] = [:], completion: (([String: Any]) -> Void)? = nil) -> String? {
        guard let socket else { return nil }
        let id = "req_\(nextID)"
        nextID += 1
        if let completion { callbacks[id] = completion }
        socket.send(json: ["type": "request", "id": id, "uri": uri, "payload": payload])
        return id
    }

    private func invalidatePointerChannel() {
        pointerGeneration += 1
        if let pointerRequestID { callbacks.removeValue(forKey: pointerRequestID) }
        pointerRequestID = nil
        requestingPointer = false
        pointerAcquisitionStarted = nil
        pointer?.close()
        pointer = nil
        pendingButtons = []
    }

    private func openPointerSocket() {
        if let started = pointerAcquisitionStarted, pointer?.isReady != true,
           ContinuousClock.now - started >= .seconds(4) { invalidatePointerChannel() }
        guard pointer == nil, !requestingPointer, let control = socket else { return }
        let generation = pointerGeneration
        requestingPointer = true
        pointerAcquisitionStarted = .now
        pointerRequestID = request("ssap://com.webos.service.networkinput/getPointerInputSocket") { [weak self] payload in
            guard let self, self.socket === control, self.pointerGeneration == generation else { return }
            self.requestingPointer = false
            self.pointerRequestID = nil
            guard let path = payload["socketPath"] as? String, let url = URL(string: path) else {
                self.pointerAcquisitionStarted = nil
                return
            }
            let ws = LocalWebSocket(url: url)
            ws.onOpen = { [weak self, weak ws] in
                guard let self, self.pointer === ws else { return }
                self.pointerAcquisitionStarted = nil
            }
            ws.onClose = { [weak self, weak ws] _ in
                guard let self, self.pointer === ws else { return }
                self.pointer = nil
                self.pointerAcquisitionStarted = nil
            }
            self.pointer = ws
            ws.start()
            // URLSessionWebSocketTask holds sends until the handshake completes.
            let queued = self.pendingButtons
            self.pendingButtons = []
            queued.forEach { ws.send("type:button\nname:\($0)\n\n") }
        }
    }

    func supports(_ key: RemoteKey) -> Bool {
        if case .search = key { return false }
        if case .input = key { return false }
        if case .powerOff = key { return false }
        return true
    }

    func send(_ key: RemoteKey) {
        guard state == .connected else {
            guard device.token != nil else { return }
            if pendingKeys.count < 10 { pendingKeys.append(key) }
            if socket == nil { open(secure: true, prompting: false) }
            return
        }
        switch key {
        case .power: request("ssap://system/turnOff")
        case .backspace: request("ssap://com.webos.service.ime/deleteCharacters", ["count": 1])
        case .enter: request("ssap://com.webos.service.ime/sendEnterKey")
        case .playPause:
            button(playing ? "PAUSE" : "PLAY")
            playing.toggle()
        default:
            if let name = Self.buttonName(key) { button(name) }
        }
    }

    func sendInteractive(_ key: RemoteKey, request: RemoteInputRequest) async {
        guard state == .connected, !request.isCancelled, !Task.isCancelled,
              let name = Self.buttonName(key), let controlSocket = socket else { return }
        let deliberate = key == .select || key == .back || key == .home
        let deadline = ContinuousClock.now + .seconds(4)
        var requestedPointer = false
        var discardRecoveryDirection = false
        while state == .connected, socket === controlSocket, !request.isCancelled, !Task.isCancelled {
            if let pointer {
                if pointer.isReady {
                    guard !discardRecoveryDirection else { return }
                    await pointer.sendAndWait("type:button\nname:\(name)\n\n")
                    return
                }
            } else {
                if !deliberate { discardRecoveryDirection = true }
                if !requestedPointer {
                    openPointerSocket()
                    requestedPointer = true
                }
                // Movement also waits through bounded acquisition, but its
                // recovery-triggering key is discarded when the channel becomes ready.
            }
            // Keep valid one-shots through channel creation/handshake. Lift cancels
            // movement; lifecycle/session cancellation also invalidates one-shots.
            guard ContinuousClock.now < deadline else {
                // Make navigation unavailable without erasing credentials or reporting
                // a failed primary address, which would trigger network rediscovery.
                disconnect()
                return
            }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
        }
    }

    var supportsCursor: Bool { true }

    func sendCursor(_ command: CursorCommand, request input: RemoteInputRequest) async -> Bool {
        guard state == .connected, !input.isCancelled, !Task.isCancelled,
              let command = command.bounded, let control = socket else { return false }
        if case let .move(dx, dy) = command {
            guard max(abs(dx), abs(dy)) <= CursorCommand.maximumPacketDelta + 0.001 else { return false }
        }
        if pointer?.isReady != true {
            openPointerSocket()
            let generation = pointerGeneration
            // Never replay a drag after recovering a socket. A new gesture can try again.
            guard !command.isContinuous else { return false }
            let deadline = ContinuousClock.now + .seconds(4)
            while pointer?.isReady != true {
                guard state == .connected, socket === control, !input.isCancelled,
                      !Task.isCancelled, pointerGeneration == generation else { return false }
                guard ContinuousClock.now < deadline else {
                    invalidatePointerChannel()
                    return false
                }
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
            }
        }
        guard state == .connected, socket === control, !input.isCancelled,
              !Task.isCancelled, let pointer, pointer.isReady else { return false }
        let packet: String
        switch command {
        case .move(let dx, let dy):
            packet = "type:move\ndx:\(Self.coordinate(dx))\ndy:\(Self.coordinate(dy))\ndown:0\n\n"
        case .scroll(let dx, let dy):
            packet = "type:scroll\ndx:\(Self.coordinate(dx))\ndy:\(Self.coordinate(dy))\n\n"
        case .click: packet = "type:click\n\n"
        case .back: packet = "type:button\nname:BACK\n\n"
        case .home: packet = "type:button\nname:HOME\n\n"
        }
        let sent = await pointer.sendReportingResult(packet)
        guard socket === control, self.pointer === pointer, state == .connected else { return false }
        if !sent { invalidatePointerChannel() }
        return sent && !input.isCancelled
    }

    private static func coordinate(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func button(_ name: String) {
        if let pointer {
            pointer.send("type:button\nname:\(name)\n\n")
        } else {
            if pendingButtons.count < 10 { pendingButtons.append(name) }
            openPointerSocket()
        }
    }

    func sendText(_ text: String) {
        request("ssap://com.webos.service.ime/insertText", ["text": text, "replace": 0])
    }

    func launch(_ app: TVApp) {
        guard state == .connected else {
            guard device.token != nil else { return }
            pendingLaunch = app
            if socket == nil { open(secure: true, prompting: false) }
            return
        }
        request("ssap://system.launcher/launch", ["id": app.launchID])
    }

    func installedApps() async -> [TVApp]? {
        guard state == .connected else { return nil }
        return await withCheckedContinuation { continuation in
            var resumed = false
            request("ssap://com.webos.applicationManager/listLaunchPoints") { payload in
                guard !resumed else { return }
                resumed = true
                let points = payload["launchPoints"] as? [[String: Any]] ?? []
                continuation.resume(returning: points.compactMap { p in
                    guard let id = p["id"] as? String, let title = p["title"] as? String else { return nil }
                    let icon = (p["largeIcon"] as? String ?? p["icon"] as? String).flatMap(URL.init(string:))
                    return TVApp(name: title, launchID: id, iconURL: icon)
                })
            }
            Task {
                try? await Task.sleep(for: .seconds(4))
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: nil)
            }
        }
    }

    private static func buttonName(_ key: RemoteKey) -> String? {
        switch key {
        case .up: "UP"
        case .down: "DOWN"
        case .left: "LEFT"
        case .right: "RIGHT"
        case .select: "ENTER"
        case .back: "BACK"
        case .home: "HOME"
        case .menu: "MENU"
        case .info: "INFO"
        case .exit: "EXIT"
        case .volumeUp: "VOLUMEUP"
        case .volumeDown: "VOLUMEDOWN"
        case .mute: "MUTE"
        case .channelUp: "CHANNELUP"
        case .channelDown: "CHANNELDOWN"
        case .rewind: "REWIND"
        case .fastForward: "FASTFORWARD"
        case .digit(let n): "\(n)"
        default: nil
        }
    }

    private static let permissions = [
        "APP_TO_APP", "CLOSE", "CONTROL_AUDIO", "CONTROL_DISPLAY", "CONTROL_INPUT_JOYSTICK",
        "CONTROL_INPUT_MEDIA_PLAYBACK", "CONTROL_INPUT_MEDIA_RECORDING", "CONTROL_INPUT_TEXT", "CONTROL_INPUT_TV",
        "CONTROL_MOUSE_AND_KEYBOARD", "CONTROL_POWER", "CONTROL_TV_SCREEN", "LAUNCH", "LAUNCH_WEBAPP",
        "READ_APP_STATUS", "READ_COUNTRY_INFO", "READ_CURRENT_CHANNEL", "READ_INPUT_DEVICE_LIST",
        "READ_INSTALLED_APPS", "READ_LGE_SDX", "READ_LGE_TV_INPUT_EVENTS", "READ_NETWORK_STATE",
        "READ_NOTIFICATIONS", "READ_POWER_STATE", "READ_RUNNING_APPS", "READ_SETTINGS", "READ_TV_CHANNEL_LIST",
        "READ_TV_CURRENT_TIME", "READ_UPDATE_INFO", "SEARCH", "TEST_OPEN", "TEST_PROTECTED", "TEST_SECURE",
        "UPDATE_FROM_REMOTE_APP", "WRITE_NOTIFICATION_ALERT", "WRITE_NOTIFICATION_TOAST", "WRITE_SETTINGS",
    ]
}
