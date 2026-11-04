import Foundation

/// Local session identity stays in the app. Only the opaque nonce and display name
/// are shared with ActivityKit; URLs never carry TV addresses or credentials.
struct RemoteActivitySession: Codable, Equatable {
    static let inactivityLimit: TimeInterval = 30 * 60
    static let lifetimeLimit: TimeInterval = 8 * 60 * 60

    let id: UUID
    let deviceID: String
    let tvName: String
    var brandName: String?
    let startedAt: Date
    private(set) var lastInteraction: Date

    init(deviceID: String, tvName: String, brandName: String? = nil, now: Date = Date(), id: UUID = UUID()) {
        self.id = id
        self.deviceID = deviceID
        self.tvName = String(tvName.unicodeScalars.prefix(80))
        self.brandName = brandName
        startedAt = now
        lastInteraction = now
    }

    var expiresAt: Date {
        min(lastInteraction.addingTimeInterval(Self.inactivityLimit),
            startedAt.addingTimeInterval(Self.lifetimeLimit))
    }

    func isValid(for selectedDeviceID: String?, at now: Date = Date()) -> Bool {
        selectedDeviceID == deviceID && now >= startedAt && now < expiresAt
    }

    @discardableResult
    mutating func recordInteraction(at now: Date = Date()) -> Bool {
        guard isValid(for: deviceID, at: now) else { return false }
        lastInteraction = max(lastInteraction, now)
        return true
    }

    func accepts(_ url: URL, selectedDeviceID: String?, at now: Date = Date(),
                 scheme: String = RemoteActivityLink.scheme) -> Bool {
        isValid(for: selectedDeviceID, at: now) && RemoteActivityLink.sessionID(in: url, scheme: scheme) == id
    }
}

enum RemoteActivityLink {
    static var scheme: String {
        Bundle.main.object(forInfoDictionaryKey: "RemoteURLScheme") as? String ?? "openremote"
    }

    static func url(for sessionID: UUID, scheme: String = scheme, eyesFree: Bool = false) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = eyesFree ? "eyes-free" : "remote"
        components.queryItems = [URLQueryItem(name: "session", value: sessionID.uuidString)]
        return components.url
    }

    static func sessionID(in url: URL, scheme: String = scheme) -> UUID? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == scheme.lowercased(), ["remote", "eyes-free"].contains(c.host ?? ""),
              c.user == nil, c.password == nil, c.port == nil, c.path.isEmpty, c.fragment == nil,
              let items = c.queryItems, items.count == 1, items[0].name == "session",
              let value = items[0].value else { return nil }
        return UUID(uuidString: value)
    }

    static func opensEyesFree(_ url: URL) -> Bool { url.host == "eyes-free" }
}
