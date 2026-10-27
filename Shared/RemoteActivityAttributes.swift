#if os(iOS)
import ActivityKit
import Foundation

struct RemoteActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var tvName: String
        var expiresAt: Date
        var brandName: String? = nil
    }

    var sessionID: UUID
}
#endif
