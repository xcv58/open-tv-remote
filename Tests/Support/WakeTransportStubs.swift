// These types never open a socket or contact a TV.
import Foundation

@MainActor
final class LocalWebSocket {
    static var instances: [LocalWebSocket] = []
    let url: URL
    var onOpen: (() -> Void)?
    var onText: ((String) -> Void)?
    var onClose: ((Error?) -> Void)?
    private(set) var sent: [String] = []
    var isReady = false
    init(url: URL) { self.url = url; Self.instances.append(self) }
    func start() { isReady = true; onOpen?() }
    func close() { isReady = false; onClose = nil }
    func send(_ text: String) { sent.append(text) }
    func send(json: [String: Any]) {
        send(String(decoding: try! JSONSerialization.data(withJSONObject: json), as: UTF8.self))
    }
    func sendAndWait(_ text: String) async { if isReady { send(text) } }
    func sendReportingResult(_ text: String) async -> Bool {
        guard isReady else { return false }
        send(text)
        return true
    }
    func reply(to uri: String, payload: [String: Any]) {
        let request = sent.compactMap(JSON.parse).last { $0["uri"] as? String == uri }!
        onText?(String(decoding: try! JSONSerialization.data(withJSONObject: ["id": request["id"]!, "payload": payload]), as: UTF8.self))
    }
    func register() { onText?("{\"type\":\"registered\",\"id\":\"register_0\",\"payload\":{}}") }
}

enum JSON {
    static func parse(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}
