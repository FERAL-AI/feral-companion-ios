import SwiftUI

/// Onboarding step 5: polls the brain's GET /api/system/permissions
/// and shows one row per Mac TCC permission. For each not-granted row,
/// an "Open on Mac" button hits POST /api/system/permissions/open.
struct MacPermissionsStepView: View {
    var onContinue: () -> Void
    @EnvironmentObject var env: AppEnvironment
    @State private var permissions: [MacPermissionRow] = []
    @State private var isLoading = true
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(spacing: FeralTheme.padLG) {
            VStack(spacing: FeralTheme.padSM) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 40))
                    .foregroundStyle(FeralTheme.accent)

                Text("Mac permissions")
                    .font(.title2.bold())
                    .foregroundStyle(FeralTheme.textPrimary)

                Text("FERAL needs certain macOS permissions to control apps on your Mac. Tap \"Open on Mac\" to grant each one.")
                    .font(.subheadline)
                    .foregroundStyle(FeralTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, FeralTheme.padXL)
            }

            if isLoading && permissions.isEmpty {
                ProgressView()
                    .tint(FeralTheme.accent)
                    .frame(height: 100)
            } else if permissions.isEmpty {
                Text("Could not reach the brain. Make sure it's running.")
                    .font(.subheadline)
                    .foregroundStyle(FeralTheme.textTertiary)
                    .padding(.horizontal, FeralTheme.padXL)
            } else {
                ScrollView {
                    LazyVStack(spacing: FeralTheme.padSM) {
                        ForEach(permissions) { perm in
                            macPermRow(perm)
                        }
                    }
                    .padding(.horizontal, FeralTheme.padXL)
                }
            }

            Spacer(minLength: 0)

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
        .onAppear {
            fetchPermissions()
            startPolling()
        }
        .onDisappear {
            stopPolling()
        }
    }

    // MARK: - Row

    private func macPermRow(_ perm: MacPermissionRow) -> some View {
        HStack(spacing: FeralTheme.padMD) {
            Image(systemName: perm.icon)
                .font(.title3)
                .foregroundStyle(perm.isGranted ? FeralTheme.stateLive : FeralTheme.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(perm.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(FeralTheme.textPrimary)
                Text(perm.setupStep)
                    .font(.caption)
                    .foregroundStyle(FeralTheme.textTertiary)
                    .lineLimit(2)
            }

            Spacer()

            if perm.isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(FeralTheme.stateLive)
            } else {
                Button("Open on Mac") {
                    Task { await openOnMac(perm.permissionKey) }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(FeralTheme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(FeralTheme.accentSoft, in: Capsule())
            }
        }
        .padding(FeralTheme.padMD)
        .feralGlass()
    }

    // MARK: - Networking

    private func fetchPermissions() {
        guard let base = env.brain.brainHTTPBase else {
            isLoading = false
            return
        }
        guard let url = URL(string: "/api/system/permissions", relativeTo: base) else { return }

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse,
                      http.statusCode == 200 else {
                    isLoading = false
                    return
                }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rows = json["permissions"] as? [[String: Any]] else {
                    isLoading = false
                    return
                }

                let parsed = rows.compactMap { MacPermissionRow(from: $0) }
                await MainActor.run {
                    self.permissions = parsed
                    self.isLoading = false
                }
            } catch {
                await MainActor.run { self.isLoading = false }
            }
        }
    }

    private func openOnMac(_ key: String) async {
        guard let base = env.brain.brainHTTPBase else { return }
        guard let url = URL(string: "/api/system/permissions/open", relativeTo: base) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["permission_key": key])

        _ = try? await URLSession.shared.data(for: request)
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            fetchPermissions()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

// MARK: - Model

struct MacPermissionRow: Identifiable {
    let id: String
    let permissionKey: String
    let displayName: String
    let status: String
    let setupStep: String

    var isGranted: Bool { status == "granted" }

    var icon: String {
        if permissionKey == "accessibility" { return "hand.tap.fill" }
        if permissionKey == "screen_recording" { return "rectangle.dashed.badge.record" }
        if permissionKey == "full_disk_access" { return "externaldrive.fill" }
        if permissionKey.hasPrefix("automation:") { return "gearshape.2.fill" }
        return "lock.shield.fill"
    }

    init?(from dict: [String: Any]) {
        guard let permission = dict["permission"] as? String,
              let status = dict["status"] as? String else { return nil }
        self.id = permission
        self.permissionKey = permission
        self.status = status
        self.setupStep = (dict["setup_step"] as? String) ?? ""

        // Build a friendly display name
        if permission == "accessibility" {
            self.displayName = "Accessibility"
        } else if permission == "screen_recording" {
            self.displayName = "Screen Recording"
        } else if permission == "full_disk_access" {
            self.displayName = "Full Disk Access"
        } else if permission.hasPrefix("automation:") {
            let bundle = String(permission.dropFirst("automation:".count))
            let friendlyNames: [String: String] = [
                "com.apple.FaceTime": "FaceTime",
                "com.apple.Music": "Music",
                "com.apple.Mail": "Mail",
                "com.apple.Notes": "Notes",
                "com.apple.MobileSMS": "Messages",
                "com.apple.Reminders": "Reminders",
                "com.apple.iCal": "Calendar",
                "com.apple.Safari": "Safari",
            ]
            self.displayName = "Automation: \(friendlyNames[bundle] ?? bundle)"
        } else {
            self.displayName = permission
        }
    }
}
