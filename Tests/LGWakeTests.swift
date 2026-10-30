import Foundation
import Testing
@testable import WakeCore

@Suite("Wake packet validation")
struct WakePacketTests {
    @Test func packetContainsOnlyTheChosenMACSixteenTimes() throws {
        let bytes = try #require(WakeOnLAN.magicPacket(mac: "AA:BB:CC:DD:EE:10"))
        #expect(bytes.count == 102)
        #expect(Array(bytes.prefix(6)) == Array(repeating: UInt8(255), count: 6))
        for i in 0..<16 { #expect(Array(bytes[(6 + i * 6)..<(12 + i * 6)]) == [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x10]) }
        #expect(WakeOnLAN.normalizedMAC(" aa-bb-cc-dd-ee-10 \n") == "AA:BB:CC:DD:EE:10")
    }

    @Test(arguments: ["", "AA:BB:CC:DD:EE", "A:BB:CC:DD:EE:10", "AA::BB:CC:DD:EE:10", "AA:BB:CC:DD:EE:GG", "00:00:00:00:00:00", "FF:FF:FF:FF:FF:FF", "01:00:5E:00:00:01"])
    func rejectsMalformedOrNonDeviceMACs(_ mac: String) {
        #expect(WakeOnLAN.macBytes(mac) == nil)
    }

    @Test func attemptsEveryDestinationAndReportsLocalSendFailures() {
        var targets: [String] = []
        let accepted = WakeOnLAN.wake(mac: "AA:BB:CC:DD:EE:10", host: "192.0.2.20") { packet, host, port in
            #expect(packet.count == 102)
            targets.append("\(host):\(port)")
            return targets.count == 1
        }
        #expect(accepted)
        #expect(targets == ["192.0.2.20:9", "192.0.2.20:7", "255.255.255.255:9", "255.255.255.255:7"])
        #expect(!WakeOnLAN.wake(mac: "AA:BB:CC:DD:EE:10", host: "192.0.2.20", send: { _, _, _ in false }))
        var sent = false
        #expect(!WakeOnLAN.wake(mac: "AA:BB:CC:DD:EE:10", host: "not-an-address", send: { _, _, _ in sent = true; return true }))
        #expect(!sent)
    }
}

@Suite("LG wake safety and recovery", .serialized)
@MainActor
struct LGWakeTests {
    private func device(mac: String? = "AA:BB:CC:DD:EE:10", token: String? = "test-key") -> TVDevice {
        TVDevice(name: "Offline test LG", brand: .lg, host: "192.0.2.20", token: token, macAddress: mac)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(condition())
    }

    @Test func connectingAndOrdinaryOfflinePowerNeverWakeOrReplayPowerOff() {
        LocalWebSocket.instances = []
        var packets = 0
        let driver = LGDriver(device: device(), sendWakePacket: { _, _ in packets += 1; return true })
        driver.send(.power)
        #expect(LocalWebSocket.instances.isEmpty)
        driver.connect()
        let control = LocalWebSocket.instances.last!
        control.register()
        #expect(driver.state == .connected)
        #expect(packets == 0)
        #expect(!control.sent.compactMap(JSON.parse).contains { $0["uri"] as? String == "ssap://system/turnOff" })
        driver.send(.power)
        #expect(control.sent.compactMap(JSON.parse).contains { $0["uri"] as? String == "ssap://system/turnOff" })
        #expect(!driver.wake())
        #expect(packets == 0)
        driver.disconnect()
    }

    @Test func wakeRequiresPairingAndAValidMAC() {
        var packets = 0
        for tv in [device(mac: nil), device(mac: "invalid"), device(token: nil)] {
            let driver = LGDriver(device: tv, sendWakePacket: { _, _ in packets += 1; return true })
            #expect(!driver.wake())
            #expect(!driver.isWaking)
        }
        #expect(packets == 0)
    }

    @Test func successRequiresRegistrationAndDiscardsAllQueuedCommands() async {
        LocalWebSocket.instances = []
        var packets: [String] = []
        let driver = LGDriver(device: device(), sendWakePacket: { mac, host in packets.append(mac + "@" + host); return true })
        driver.send(.up)
        #expect(driver.wake())
        #expect(!driver.wake())
        #expect(driver.isWaking && driver.state == .connecting)
        driver.send(.power)
        driver.send(.up)
        driver.sendText("must not be queued")
        driver.launch(TVApp(name: "Do not launch", launchID: "test"))
        await waitUntil { LocalWebSocket.instances.count == 2 }
        let control = LocalWebSocket.instances.last!
        #expect(driver.state != .connected)
        control.register()
        #expect(driver.state == .connected && !driver.isWaking)
        #expect(packets == ["AA:BB:CC:DD:EE:10@192.0.2.20"])
        let uris = control.sent.compactMap(JSON.parse).compactMap { $0["uri"] as? String }
        #expect(!uris.contains("ssap://system/turnOff"))
        #expect(!uris.contains("ssap://system.launcher/launch"))
        #expect(!uris.contains("ssap://com.webos.service.ime/insertText"))
        control.reply(to: "ssap://com.webos.service.networkinput/getPointerInputSocket", payload: ["socketPath": "ws://192.0.2.20/pointer"])
        #expect(LocalWebSocket.instances.last!.sent.isEmpty)
        driver.disconnect()
    }

    @Test func cancelStopsRetriesAndLateRegistration() async {
        LocalWebSocket.instances = []
        var packets = 0
        let driver = LGDriver(device: device(), sendWakePacket: { _, _ in packets += 1; return true }, wakeInterval: .milliseconds(20))
        #expect(driver.wake())
        await waitUntil { !LocalWebSocket.instances.isEmpty }
        let late = LocalWebSocket.instances.last!.onText
        driver.disconnect()
        late?("{\"type\":\"registered\",\"id\":\"register_0\",\"payload\":{}}")
        try? await Task.sleep(for: .milliseconds(80))
        #expect(packets == 1)
        #expect(driver.state == .idle && !driver.isWaking)
    }

    @Test func retriesAreBoundedAndTimeoutDoesNotClaimConnection() async {
        LocalWebSocket.instances = []
        var packets = 0
        let driver = LGDriver(device: device(), sendWakePacket: { _, _ in packets += 1; return true }, wakeInterval: .milliseconds(3))
        #expect(driver.wake())
        await waitUntil { if case .failed = driver.state { return true }; return false }
        #expect(!driver.isWaking)
        #expect(packets == 5)
        let count = packets
        try? await Task.sleep(for: .milliseconds(30))
        #expect(packets == count)
    }

    @Test func localSendFailureStartsNoReconnectAndReportsFailure() {
        LocalWebSocket.instances = []
        let driver = LGDriver(device: device(), sendWakePacket: { _, _ in false })
        #expect(!driver.wake())
        #expect(!driver.isWaking && LocalWebSocket.instances.isEmpty)
        guard case .failed(let text) = driver.state else { Issue.record("Expected explicit send failure"); return }
        #expect(text.contains("Local Network"))
    }

    @Test func learnsOnlyTheMatchingNetworkInterfaceAndPreservesManualAddress() {
        let info: [String: Any] = ["wifiInfo": ["macAddress": "AA:BB:CC:DD:EE:10"], "wiredInfo": ["macAddress": "AA:BB:CC:DD:EE:20"]]
        let status: [String: Any] = ["wifi": ["state": "connected", "ipAddress": "192.0.2.20"], "wired": ["state": "disconnected"]]
        #expect(LGDriver.wakeAddress(info: info, status: status, host: "192.0.2.20") == "AA:BB:CC:DD:EE:10")
        #expect(LGDriver.wakeAddress(info: info, status: [:], host: "192.0.2.20") == nil)
        #expect(LGDriver.wakeAddress(info: ["wifiInfo": ["macAddress": "AA:BB:CC:DD:EE:10"]], status: ["wired": ["state": "connected", "ipAddress": "192.0.2.20"]], host: "192.0.2.20") == nil)
        #expect(LGDriver.wakeAddress(info: ["wifiInfo": ["macAddress": "AA:BB:CC:DD:EE:10"]], status: [:], host: "192.0.2.20") == "AA:BB:CC:DD:EE:10")
        LocalWebSocket.instances = []
        let driver = LGDriver(device: device(mac: nil), sendWakePacket: { _, _ in Issue.record("Must not wake while learning"); return false })
        driver.connect()
        let control = LocalWebSocket.instances.last!
        control.register()
        control.reply(to: "ssap://com.webos.service.connectionmanager/getStatus", payload: status)
        control.reply(to: "ssap://com.webos.service.connectionmanager/getinfo", payload: info)
        #expect(driver.device.macAddress == "AA:BB:CC:DD:EE:10")
        driver.disconnect()
        let manual = LGDriver(device: device(mac: "AA:BB:CC:DD:EE:30"), sendWakePacket: { _, _ in false })
        manual.connect()
        let manualControl = LocalWebSocket.instances.last!
        manualControl.register()
        #expect(!manualControl.sent.contains { $0.contains("connectionmanager") })
        #expect(manual.device.macAddress == "AA:BB:CC:DD:EE:30")
        manual.disconnect()
    }

    @Test func credentialRejectionEndsWakeAndRequiresExplicitPairing() async {
        LocalWebSocket.instances = []
        var packets = 0
        let driver = LGDriver(device: device(), sendWakePacket: { _, _ in packets += 1; return true }, wakeInterval: .milliseconds(20))
        #expect(driver.wake())
        await waitUntil { !LocalWebSocket.instances.isEmpty }
        LocalWebSocket.instances.last!.onText?("{\"type\":\"error\",\"id\":\"register_0\",\"payload\":{}}")
        try? await Task.sleep(for: .milliseconds(80))
        #expect(driver.device.token == nil && !driver.isWaking)
        #expect(packets == 1)
        #expect(!driver.wake())
        guard case .failed = driver.state else { Issue.record("Expected pairing failure"); return }
    }
}
