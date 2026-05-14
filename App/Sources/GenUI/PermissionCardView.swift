import SwiftUI
import UIKit

// Phase 7a (audit-r10 overhaul) — iOS renderer for the brain's
// `permission_card` SDUI element (introduced by Phase 6 on the brain
// side). The card lands in the chat stream when a Phase 4 skill
// returns `permission_denied:<NSKey>`; this view renders the
// pre-canned copy from `agents/permission_card.py:PERMISSION_CATALOG`
// and a button that opens the supplied iOS deeplink.
//
// Notable: no LLM-generated prose, no client-side hardcoded titles.
// All user-visible strings flow from the catalog so there's one
// place to edit copy + one place to add new permission keys when a
// future skill registers an unfamiliar framework.
struct PermissionCardView: View {
    let permissionKey: String
    let title: String
    let description: String
    let deeplink: String
    let deeplinkLabel: String

    @State private var isOpening = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.title3)
                    .foregroundStyle(.orange)
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }

            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    openDeeplink()
                } label: {
                    HStack(spacing: 6) {
                        if isOpening {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "gearshape.fill")
                        }
                        Text(deeplinkLabel)
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.accentColor)
                    )
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                if !permissionKey.isEmpty {
                    Text(permissionKey)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title). \(description)"))
        .accessibilityAddTraits(.isStaticText)
    }

    private func openDeeplink() {
        guard let url = URL(string: deeplink) else { return }
        guard UIApplication.shared.canOpenURL(url) else {
            // Fallback: try the app's own settings page if a custom
            // scheme (e.g. `x-apple-health://`) isn't installed on
            // this device. `app-settings:` is the safe universal
            // jump for any iOS app post-iOS 8.
            let fallback = URL(string: UIApplication.openSettingsURLString)
            if let fallback {
                UIApplication.shared.open(fallback)
            }
            return
        }
        isOpening = true
        UIApplication.shared.open(url) { _ in
            isOpening = false
        }
    }
}
