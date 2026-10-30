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
    private var wakeTask: Task<Void, Never>?
    private var wakeGeneration = 0
    private let sendWakePacket: (String, String) -> Bool
    private let wakeInterval: Duration

    var isWaking: Bool { wakeTask != nil }

    init(device: TVDevice, sendWakePacket: @escaping (String, String) -> Bool = { WakeOnLAN.wake(mac: $0, host: $1) },
         wakeInterval: Duration = .seconds(3)) {
        self.device = device
        self.sendWakePacket = sendWakePacket
        self.wakeInterval = wakeInterval
    }

    func connect() {
        cancelWake()
        guard device.token != nil else {
            state = .unpaired
            return
        }
        open(secure: true, prompting: false)
    }

    func pair() {
        cancelWake()
        open(secure: true, prompting: true)
    }
    func submitPairingCode(_ code: String) {}

    func disconnect() {
        cancelWake()
        socket?.close()
        pointer?.close()
        socket = nil
        pointer = nil
        callbacks = [:]
        pendingLaunch = nil
        pendingKeys = []
        pendingButtons = []
        requestingPointer = false
        state = .idle
    }

    /// Explicit wake action only. A connection, discovery, or a queued Power press never wakes a TV.
    @discardableResult
    func wake() -> Bool {
        guard !isWaking, state != .connected, device.token != nil,
              let mac = device.macAddress, WakeOnLAN.macBytes(mac) != nil else { return false }
        // No old command may run after the TV wakes, especially turnOff.
        pendingKeys = []
        pendingButtons = []
        pendingLaunch = nil
        callbacks = [:]
        socket?.close()
        pointer?.close()
        socket = nil
        pointer = nil
        requestingPointer = false
        guard sendWakePacket(mac, device.host) else {
            state = .failed("Couldn't send the wake request. Check Local Network access and your Wi-Fi connection.")
            return false
        }
        wakeGeneration += 1
        let generation = wakeGeneration
        wakeTask = Task { [weak self] in
            for attempt in 0..<5 {
                guard let self, !Task.isCancelled, self.wakeGeneration == generation else { return }
                if attempt > 0 { _ = self.sendWakePacket(mac, self.device.host) }
                self.open(secure: true, prompting: false)
                do { try await Task.sleep(for: self.wakeInterval) } catch { return }
                guard self.wakeGeneration == generation, self.state != .connected else { return }
            }
            guard let self, self.wakeGeneration == generation, !Task.isCancelled else { return }
            self.cancelWake()
            self.socket?.close()
            self.pointer?.close()
            self.socket = nil
            self.pointer = nil
            self.callbacks = [:]
            self.requestingPointer = false
            self.state = .failed("The TV didn't respond. Check its MAC address and enable TV On With Mobile → Turn on via Wi-Fi in the TV's settings. Some models require Ethernet or different standby settings.")
        }
        state = .connecting
        return true
    }

    private func cancelWake() {
        wakeGeneration += 1
        wakeTask?.cancel()
        wakeTask = nil
    }

    private func open(secure: Bool, prompting: Bool) {
        socket?.close()
        pointer?.close()
        pointer = nil
        let url = URL(string: secure ? "wss://\(device.host):3001" : "ws://\(device.host):3000")!
        let ws = LocalWebSocket(url: url)
        state = .connecting
        var opened = false
        ws.onOpen = { [weak self, weak ws] in
            guard let self, let ws, self.socket === ws else { return }
            opened = true
            self.register(prompting: prompting)
        }
        ws.onText = { [weak self, weak ws] text in
            guard let self, let ws, self.socket === ws, let json = JSON.parse(text) else { return }
            if (json["id"] as? String) == "register_0" {
                self.handleRegistration(json)
            } else if let id = json["id"] as? String, let callback = self.callbacks.removeValue(forKey: id) {
                callback(json["payload"] as? [String: Any] ?? [:])
            }
        }
        ws.onClose = { [weak self, weak ws] _ in
            guard let self, let ws, self.socket === ws else { return }
            self.socket = nil
            if !opened && secure {
                // Older firmware only speaks plain ws on 3000.
                self.open(secure: false, prompting: prompting)
            } else if self.isWaking {
                // The bounded wake task retries without discovering or pairing other devices.
                return
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
            cancelWake()
            if let key = payload?["client-key"] as? String, key != device.token {
                device.token = key
                delegate?.driver(self, didUpdateDevice: device)
            }
            state = .connected
            refreshWakeAddress()
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
            cancelWake()
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

    private func refreshWakeAddress() {
        guard device.macAddress == nil else { return }
        request("ssap://com.webos.service.connectionmanager/getStatus") { [weak self] status in
            guard let self else { return }
            self.request("ssap://com.webos.service.connectionmanager/getinfo") { [weak self] info in
                guard let self, self.device.macAddress == nil,
                      let mac = Self.wakeAddress(info: info, status: status, host: self.device.host) else { return }
                self.device.macAddress = mac
                self.delegate?.driver(self, didUpdateDevice: self.device)
            }
        }
    }

    /// Choose the interface serving this TV address; never guess between Wi-Fi and Ethernet.
    static func wakeAddress(info: [String: Any], status: [String: Any], host: String) -> String? {
        let interfaces = [("wired", "wiredInfo"), ("wifi", "wifiInfo")]
        for (connection, details) in interfaces {
            guard let network = status[connection] as? [String: Any],
                  network["state"] as? String == "connected", network["ipAddress"] as? String == host,
                  let values = info[details] as? [String: Any], let raw = values["macAddress"] as? String,
                  let mac = WakeOnLAN.normalizedMAC(raw) else { continue }
            return mac
        }
        if interfaces.contains(where: { (status[$0.0] as? [String: Any])?["state"] as? String == "connected" }) {
            return nil
        }
        let known = Set(interfaces.compactMap { _, details -> String? in
            guard let values = info[details] as? [String: Any], let raw = values["macAddress"] as? String else { return nil }
            return WakeOnLAN.normalizedMAC(raw)
        })
        return known.count == 1 ? known.first : nil
    }

    private func request(_ uri: String, _ payload: [String: Any] = [:], completion: (([String: Any]) -> Void)? = nil) {
        guard let socket else { return }
        let id = "req_\(nextID)"
        nextID += 1
        if let completion { callbacks[id] = completion }
        socket.send(json: ["type": "request", "id": id, "uri": uri, "payload": payload])
    }

    private func openPointerSocket() {
        guard pointer == nil, !requestingPointer else { return }
        requestingPointer = true
        request("ssap://com.webos.service.networkinput/getPointerInputSocket") { [weak self] payload in
            guard let self else { return }
            self.requestingPointer = false
            guard let path = payload["socketPath"] as? String, let url = URL(string: path) else { return }
            let ws = LocalWebSocket(url: url)
            ws.onClose = { [weak self] _ in self?.pointer = nil }
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
        guard !isWaking else { return }
        guard state == .connected else {
            // Power off is never queued for later replay. Waking has its own explicit action.
            guard key != .power else { return }
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

    private func button(_ name: String) {
        if let pointer {
            pointer.send("type:button\nname:\(name)\n\n")
        } else {
            if pendingButtons.count < 10 { pendingButtons.append(name) }
            openPointerSocket()
        }
    }

    func sendText(_ text: String) {
        guard state == .connected, !isWaking else { return }
        request("ssap://com.webos.service.ime/insertText", ["text": text, "replace": 0])
    }

    func launch(_ app: TVApp) {
        guard !isWaking else { return }
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
