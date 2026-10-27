#if os(iOS)
import SwiftUI

struct RemoteActivityPinButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let controller = model.remoteActivity
        let pinned = controller.session != nil
        Button {
            if pinned { controller.dismiss() }
            else { model.pinRemoteActivity() }
        } label: {
            Group {
                if controller.isBusy { ProgressView().controlSize(.small) }
                else { Image(systemName: pinned ? "pin.fill" : "pin").font(.system(size: 17, weight: .semibold)) }
            }
            .foregroundStyle(pinned ? Theme.accent : Theme.secondary)
            .frame(width: 40, height: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.current == nil || controller.isBusy)
        .accessibilityLabel(pinned ? "Dismiss remote shortcut" : "Show remote in Dynamic Island and Lock Screen")
        .accessibilityHint("The shortcut expires after 30 minutes without remote input.")
        .accessibilityIdentifier("pinRemoteActivity")
    }
}
#endif
