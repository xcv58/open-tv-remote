import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct RemoteActivityWidgets: WidgetBundle {
    var body: some Widget { RemoteActivityWidget() }
}

struct RemoteActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RemoteActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "av.remote.fill").font(.title2).foregroundStyle(.mint)
                    title(context)
                }
                controls(context)
            }
            .padding(14)
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
            .widgetURL(RemoteActivityLink.url(for: context.attributes.sessionID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if let url = RemoteActivityLink.url(for: context.attributes.sessionID, eyesFree: true) {
                        Link(destination: url) {
                            Label("Open eyes-free", systemImage: "hand.draw")
                                .font(.caption2.weight(.semibold)).foregroundStyle(.mint)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                .frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .padding(.leading, 6)
                        .accessibilityLabel("Open eyes-free")
                    }
                }
                // The full name belongs below the camera, where it can wrap.
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        title(context)
                        controls(context)
                    }
                    .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 12)
                }
            } compactLeading: {
                Image(systemName: "av.remote.fill").foregroundStyle(.mint)
            } compactTrailing: {
                if context.isStale {
                    Image(systemName: "clock.badge.exclamationmark").accessibilityLabel("Remote session expired")
                } else {
                    Text(context.state.brandName ?? String(context.state.tvName.split(separator: " ").first ?? "TV"))
                        .font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
                }
            } minimal: {
                Image(systemName: context.isStale ? "clock.badge.exclamationmark" : "av.remote.fill")
            }
            .widgetURL(RemoteActivityLink.url(for: context.attributes.sessionID))
            .keylineTint(.mint)
        }
    }

    private func title(_ context: ActivityViewContext<RemoteActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(context.state.tvName).font(.headline).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if context.isStale { Text("Session expired").font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func controls(_ context: ActivityViewContext<RemoteActivityAttributes>) -> some View {
        HStack(spacing: 10) {
            if let url = RemoteActivityLink.url(for: context.attributes.sessionID) {
                Link(destination: url) {
                    Label("Open", systemImage: "av.remote")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(.mint, in: Capsule()).foregroundStyle(.black)
                }
                .accessibilityLabel("Open remote")
                .accessibilityHint("Resume your current remote view.")
            }
            if !context.isStale {
                Button(intent: DisconnectRemoteActivityIntent(sessionID: context.attributes.sessionID)) {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(.white.opacity(0.14), in: Capsule()).foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Disconnect TV remote")
                .accessibilityHint("Ends the remote session and keeps the TV paired.")
            }
        }
        .font(.subheadline.weight(.semibold))
    }

}

#Preview("Remote session", as: .content, using: RemoteActivityAttributes(sessionID: UUID())) {
    RemoteActivityWidget()
} contentStates: {
    RemoteActivityAttributes.ContentState(tvName: "Roku Streaming Stick Plus", expiresAt: Date().addingTimeInterval(1800), brandName: "Roku")
}
