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
                    Spacer(minLength: 0)
                    dismissButton(context.attributes.sessionID)
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
                DynamicIslandExpandedRegion(.trailing) {
                    dismissButton(context.attributes.sessionID).padding(.trailing, 6)
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
                    Label("Resume remote", systemImage: "av.remote")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(.mint, in: Capsule()).foregroundStyle(.black)
                }
            }
            if !context.isStale {
                Button(intent: DisconnectRemoteActivityIntent(sessionID: context.attributes.sessionID)) {
                    Label("Disconnect", systemImage: "wifi.slash")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(.white.opacity(0.14), in: Capsule()).foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.subheadline.weight(.semibold))
    }

    private func dismissButton(_ id: UUID) -> some View {
        Button(intent: DismissRemoteActivityIntent(sessionID: id)) {
            Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                .frame(width: 44, height: 44).contentShape(Circle())
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain).accessibilityLabel("Dismiss remote shortcut")
    }
}

#Preview("Remote session", as: .content, using: RemoteActivityAttributes(sessionID: UUID())) {
    RemoteActivityWidget()
} contentStates: {
    RemoteActivityAttributes.ContentState(tvName: "Roku Streaming Stick Plus", expiresAt: Date().addingTimeInterval(1800), brandName: "Roku")
}
