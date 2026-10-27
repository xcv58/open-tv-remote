import Foundation

/// A Jellyfin server on the local network: its HTTP API for browsing, signing in, and telling
/// another Jellyfin client (like the app on the TV) what to play.
struct JellyfinAPI: Sendable {
    let baseURL: URL
    let deviceID: String
    var token: String?

    enum Failure: LocalizedError {
        case status(Int)
        case unreachable

        var errorDescription: String? {
            switch self {
            case .status(401): "Jellyfin rejected the sign-in."
            case .status(let code): "Jellyfin returned an error (\(code))."
            case .unreachable: "Couldn't reach the Jellyfin server."
            }
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: LocalTrustDelegate(), delegateQueue: nil)
    }()

    private static let decoder = JSONDecoder()

    private var authorization: String {
        #if os(macOS)
        let device = "Mac"
        #else
        let device = "iPhone"
        #endif
        var fields = ["Client=\"Remote Lab\"", "Device=\"\(device)\"", "DeviceId=\"\(deviceID)\"", "Version=\"1.0\""]
        if let token { fields.append("Token=\"\(token)\"") }
        return "MediaBrowser " + fields.joined(separator: ", ")
    }

    private func request(_ method: String, _ path: String, query: [String: String?] = [:], body: [String: Any]? = nil) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        if !items.isEmpty { components.queryItems = items.sorted { $0.name < $1.name } }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        guard let (data, response) = try? await Self.session.data(for: req),
              let http = response as? HTTPURLResponse else { throw Failure.unreachable }
        guard (200..<300).contains(http.statusCode) else { throw Failure.status(http.statusCode) }
        return data
    }

    private func get<T: Decodable>(_ path: String, _ query: [String: String?] = [:]) async throws -> T {
        try Self.decoder.decode(T.self, from: try await request("GET", path, query: query))
    }

    // MARK: Server

    static func publicInfo(_ baseURL: URL) async -> JellyfinServerInfo? {
        guard let (data, _) = try? await session.data(from: baseURL.appendingPathComponent("System/Info/Public")) else { return nil }
        return try? decoder.decode(JellyfinServerInfo.self, from: data)
    }

    // MARK: Sign-in

    func quickConnectEnabled() async -> Bool {
        (try? await request("GET", "QuickConnect/Enabled")).map { String(decoding: $0, as: UTF8.self) == "true" } ?? false
    }

    func initiateQuickConnect() async throws -> QuickConnectState {
        try Self.decoder.decode(QuickConnectState.self, from: try await request("POST", "QuickConnect/Initiate"))
    }

    func quickConnectState(secret: String) async throws -> QuickConnectState {
        try await get("QuickConnect/Connect", ["secret": secret])
    }

    func authenticate(quickConnectSecret secret: String) async throws -> JellyfinAuth {
        try Self.decoder.decode(JellyfinAuth.self, from: try await request("POST", "Users/AuthenticateWithQuickConnect", body: ["Secret": secret]))
    }

    func authenticate(username: String, password: String) async throws -> JellyfinAuth {
        try Self.decoder.decode(JellyfinAuth.self, from: try await request("POST", "Users/AuthenticateByName", body: ["Username": username, "Pw": password]))
    }

    // MARK: Library

    private static let fields = "Overview,PrimaryImageAspectRatio"

    func views(user: String) async throws -> [JellyfinItem] {
        let result: JellyfinItems = try await get("UserViews", ["userId": user])
        return result.items
    }

    func resume(user: String) async throws -> [JellyfinItem] {
        let result: JellyfinItems = try await get("UserItems/Resume", ["userId": user, "mediaTypes": "Video", "limit": "20", "fields": Self.fields])
        return result.items
    }

    func nextUp(user: String) async throws -> [JellyfinItem] {
        let result: JellyfinItems = try await get("Shows/NextUp", ["userId": user, "limit": "20", "fields": Self.fields])
        return result.items
    }

    func items(user: String, parent: String, search: String? = nil) async throws -> [JellyfinItem] {
        let result: JellyfinItems = try await get("Items", [
            "userId": user, "parentId": parent, "includeItemTypes": "Series,Movie,Video,Folder,BoxSet",
            "sortBy": "SortName", "fields": Self.fields, "limit": "500",
            "searchTerm": search, "recursive": search == nil ? nil : "true",
        ])
        return result.items
    }

    func search(user: String, term: String) async throws -> [JellyfinItem] {
        let result: JellyfinItems = try await get("Items", [
            "userId": user, "searchTerm": term, "recursive": "true", "includeItemTypes": "Series,Movie,Episode",
            "fields": Self.fields, "limit": "50",
        ])
        return result.items
    }

    func item(user: String, id: String) async throws -> JellyfinItem {
        try await get("Items/\(id)", ["userId": user])
    }

    /// The episode to watch next in one series.
    func nextUp(user: String, series: String) async throws -> JellyfinItem? {
        let result: JellyfinItems = try await get("Shows/NextUp", ["userId": user, "seriesId": series, "limit": "1"])
        return result.items.first
    }

    func seasons(user: String, series: String) async throws -> [JellyfinItem] {
        let result: JellyfinItems = try await get("Shows/\(series)/Seasons", ["userId": user])
        return result.items
    }

    func episodes(user: String, series: String, season: String) async throws -> [JellyfinItem] {
        let result: JellyfinItems = try await get("Shows/\(series)/Episodes", ["userId": user, "seasonId": season, "fields": Self.fields])
        return result.items
    }

    /// `wide` asks for a 16:9 picture: an episode's own still, or a movie's or show's backdrop.
    func imageURL(_ item: JellyfinItem, width: Int, wide: Bool = false) -> URL? {
        let id: String
        var type = "Primary"
        if wide && item.type != "Episode" && item.type != "CollectionFolder" {
            id = item.id
            type = "Backdrop"
        } else if item.imageTags?["Primary"] != nil { id = item.id }
        else if let series = item.seriesID { id = series }
        else { return nil }
        var c = URLComponents(url: baseURL.appendingPathComponent("Items/\(id)/Images/\(type)"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "fillWidth", value: "\(width)"), URLQueryItem(name: "quality", value: "85")]
        return c.url
    }

    // MARK: Remote control

    func sessions(user: String) async throws -> [JellyfinSession] {
        let all: [JellyfinSession] = try await get("Sessions", ["controllableByUserId": user, "activeWithinSeconds": "960"])
        return all.filter { $0.supportsRemoteControl && $0.deviceID != deviceID }
    }

    enum PlayCommand: String { case now = "PlayNow", shuffle = "PlayShuffle" }

    /// Shuffle takes a container (a series, a season) and plays everything in it in random order.
    func play(_ items: [String], on session: String, command: PlayCommand = .now, startTicks: Int64? = nil) async throws {
        _ = try await request("POST", "Sessions/\(session)/Playing", query: [
            "playCommand": command.rawValue, "itemIds": items.joined(separator: ","), "startPositionTicks": startTicks.map(String.init),
        ])
    }

    enum PlayState: String { case playPause = "PlayPause", stop = "Stop", next = "NextTrack", previous = "PreviousTrack", seek = "Seek" }

    func send(_ command: PlayState, to session: String, seekTicks: Int64? = nil) async throws {
        _ = try await request("POST", "Sessions/\(session)/Playing/\(command.rawValue)", query: ["seekPositionTicks": seekTicks.map(String.init)])
    }
}

// MARK: - Models

struct JellyfinServerInfo: Decodable, Hashable, Sendable {
    let id: String
    let serverName: String
    let version: String?

    enum CodingKeys: String, CodingKey { case id = "Id", serverName = "ServerName", version = "Version" }
}

struct QuickConnectState: Decodable, Sendable {
    let secret: String
    let code: String
    let authenticated: Bool

    enum CodingKeys: String, CodingKey { case secret = "Secret", code = "Code", authenticated = "Authenticated" }
}

struct JellyfinAuth: Decodable, Sendable {
    let accessToken: String
    let user: User

    struct User: Decodable, Sendable {
        let id: String
        let name: String
        enum CodingKeys: String, CodingKey { case id = "Id", name = "Name" }
    }

    enum CodingKeys: String, CodingKey { case accessToken = "AccessToken", user = "User" }
}

struct JellyfinItems: Decodable, Sendable {
    let items: [JellyfinItem]
    enum CodingKeys: String, CodingKey { case items = "Items" }
}

struct JellyfinItem: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let type: String
    let collectionType: String?
    let seriesName: String?
    let seriesID: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let year: Int?
    let overview: String?
    let runTimeTicks: Int64?
    let imageTags: [String: String]?
    let userData: UserData?

    struct UserData: Decodable, Hashable, Sendable {
        let playbackPositionTicks: Int64?
        let played: Bool?
        enum CodingKeys: String, CodingKey { case playbackPositionTicks = "PlaybackPositionTicks", played = "Played" }
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", type = "Type", collectionType = "CollectionType", seriesName = "SeriesName"
        case seriesID = "SeriesId", seasonNumber = "ParentIndexNumber", episodeNumber = "IndexNumber"
        case year = "ProductionYear", overview = "Overview", runTimeTicks = "RunTimeTicks", imageTags = "ImageTags"
        case userData = "UserData"
    }

    var isPlayable: Bool { ["Episode", "Movie", "Video", "MusicVideo"].contains(type) }
    /// How far through it the user is, 0...1, if they've started it.
    var progress: Double? {
        guard let position = resumeTicks, let total = runTimeTicks, total > 0 else { return nil }
        return min(1, Double(position) / Double(total))
    }

    var resumeTicks: Int64? { userData?.playbackPositionTicks.flatMap { $0 > 0 ? $0 : nil } }

    /// "S2 · E5 · Title" for episodes, the plain name otherwise.
    var label: String {
        guard type == "Episode" else { return name }
        let parts = [seasonNumber.map { "S\($0)" }, episodeNumber.map { "E\($0)" }].compactMap { $0 }
        return parts.isEmpty ? name : parts.joined(separator: " · ") + " · " + name
    }
}

struct JellyfinSession: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let deviceID: String?
    let deviceName: String?
    let client: String?
    let remoteEndPoint: String?
    let remoteControl: Bool?
    let nowPlaying: JellyfinItem?
    let playState: PlayState?

    struct PlayState: Decodable, Hashable, Sendable {
        let positionTicks: Int64?
        let isPaused: Bool?
        enum CodingKeys: String, CodingKey { case positionTicks = "PositionTicks", isPaused = "IsPaused" }
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id", deviceID = "DeviceId", deviceName = "DeviceName", client = "Client"
        case remoteControl = "SupportsRemoteControl", nowPlaying = "NowPlayingItem", playState = "PlayState"
        case remoteEndPoint = "RemoteEndPoint"
    }

    var supportsRemoteControl: Bool { remoteControl ?? false }
    /// Whether this session's app connects from `host`. The server may report an IPv4-mapped IPv6 address.
    func isAt(_ host: String) -> Bool {
        guard let remoteEndPoint else { return false }
        return remoteEndPoint == host || remoteEndPoint.hasSuffix(":\(host)")
    }
    var title: String { [deviceName, client].compactMap { $0 }.joined(separator: " · ") }
}

extension Int64 {
    static let ticksPerSecond: Int64 = 10_000_000
}
