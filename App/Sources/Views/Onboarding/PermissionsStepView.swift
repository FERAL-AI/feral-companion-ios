import SwiftUI

/// Onboarding step 3: walks through every iOS permission FERAL needs.
/// Each row shows the current status and a button to request/grant.
struct PermissionsStepView: View {
    var onContinue: () -> Void

    /// Tracks statuses per-key so the UI updates live after grants.
    @State private var statuses: [PermissionKey: PermissionStatus] = [:]

    /// Priority-ordered list of permissions shown in the wizard.
    private let permissionOrder: [PermissionKey] = [
        .bluetooth,
        .microphone,
        .camera,
        .contacts,
        .music,
        .calendars,
        .location,
        .health,
    ]

    var body: some View {
        VStack(spacing: FeralTheme.padLG) {
            VStack(spacing: FeralTheme.padSM) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(FeralTheme.accent)

                Text("Permissions")
                    .font(.title2.bold())
                    .foregroundStyle(FeralTheme.textPrimary)

                Text("FERAL works best with these permissions. You can grant them now or later in Settings.")
                    .font(.subheadline)
                    .foregroundStyle(FeralTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, FeralTheme.padXL)
            }

            ScrollView {
                LazyVStack(spacing: FeralTheme.padSM) {
                    ForEach(permissionOrder) { key in
                        permissionRow(key)
                    }
                }
                .padding(.horizontal, FeralTheme.padXL)
            }

            Button(action: onContinue) {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, FeralTheme.padMD)
            }
            .buttonStyle(.borderedProminent)
            .tint(FeralTheme.accent)
            .padding(.horizontal, FeralTheme.padXL)
            .padding(.bottom, FeralTheme.padLG)
        }
        .onAppear { refreshAll() }
    }

    // MARK: - Row

    private func permissionRow(_ key: PermissionKey) -> some View {
        HStack(spacing: FeralTheme.padMD) {
            Image(systemName: key.icon)
                .font(.title3)
                .foregroundStyle(FeralTheme.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(key.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(FeralTheme.textPrimary)
                Text(key.whyCopy)
                    .font(.caption)
                    .foregroundStyle(FeralTheme.textTertiary)
                    .lineLimit(2)
            }

            Spacer()

            statusBadge(for: key)
        }
        .padding(FeralTheme.padMD)
        .feralGlass()
    }

    @ViewBuilder
    private func statusBadge(for key: PermissionKey) -> some View {
        let status = statuses[key] ?? .unknown
        switch status {
        case .granted:
            Text("Granted")
                .font(.caption.weight(.semibold))
                .foregroundStyle(FeralTheme.stateLive)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(FeralTheme.stateLiveSoft, in: Capsule())

        case .denied:
            Button("Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(FeralTheme.stateWarn)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(FeralTheme.stateWarnSoft, in: Capsule())

        case .notDetermined:
            Button("Grant") {
                Task {
                    await PermissionProbes.requestAccess(for: key)
                    refreshAll()
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(FeralTheme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(FeralTheme.accentSoft, in: Capsule())

        default:
            Text(status.displayLabel)
                .font(.caption)
                .foregroundStyle(FeralTheme.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(FeralTheme.surface1, in: Capsule())
        }
    }

    private func refreshAll() {
        for key in permissionOrder {
            statuses[key] = PermissionProbes.checkStatus(for: key)
        }
    }
}
