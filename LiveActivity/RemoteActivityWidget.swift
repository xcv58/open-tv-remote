import ActivityKit
import SwiftUI
import WidgetKit

@main
struct RemoteActivityWidgets: WidgetBundle {
    var body: some Widget { RemoteActivityWidget() }
}

struct RemoteActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RemoteActivityAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: "av.remote.fill").font(.title)
                VStack(alignment: .leading, spacing: 5) {
                    Text(context.state.tvName).font(.headline).lineLimit(1)
                    Text(context.isStale ? "Session expired · Open app to pin again" : "Tap to open eyes-free remote")
                        .font(.subheadline)
                    if !context.isStale {
                        Text("Expires \(context.state.expiresAt, style: .relative)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding()
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
            .widgetURL(RemoteActivityLink.url(for: context.attributes.sessionID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "av.remote.fill").foregroundStyle(.mint)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.tvName).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        Label(context.isStale ? "Session expired · Open app" : "Open eyes-free remote",
                              systemImage: context.isStale ? "clock.badge.exclamationmark" : "l.joystick.tilt.up.fill")
                            .font(.subheadline)
                        if !context.isStale {
                            Text("Expires \(context.state.expiresAt, style: .relative)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
            } compactLeading: {
                Image(systemName: "av.remote.fill").foregroundStyle(.mint)
            } compactTrailing: {
                if context.isStale {
                    Image(systemName: "clock.badge.exclamationmark").accessibilityLabel("Remote session expired")
                } else {
                    Text(context.state.tvName).lineLimit(1).frame(maxWidth: 70)
                }
            } minimal: {
                Image(systemName: context.isStale ? "clock.badge.exclamationmark" : "av.remote.fill")
            }
            .widgetURL(RemoteActivityLink.url(for: context.attributes.sessionID))
            .keylineTint(.mint)
        }
    }
}

#Preview("Pinned remote", as: .content, using: RemoteActivityAttributes(sessionID: UUID())) {
    RemoteActivityWidget()
} contentStates: {
    RemoteActivityAttributes.ContentState(tvName: "Living Room LG", expiresAt: Date().addingTimeInterval(1800))
}
