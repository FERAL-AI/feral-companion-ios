import AppIntents
import Foundation
import UIKit

// Phase 4 (audit-r10 overhaul plan) — App Intents bridge.
//
// Operator demand: "state of the art". Apple's modern surface for
// "let other apps + the system + Siri ask FERAL to do things" is
// App Intents (iOS 16+). Each Phase 4 skill ships BOTH a FERAL HUP
// action handler AND an `AppIntent` declaration here so:
//
//   - "Hey Siri, FERAL call Mom" routes through the same code path
//     the brain uses when it dispatches `phone.call.start`.
//   - Shortcuts / Spotlight / Action Button / Smart Stack can invoke
//     FERAL skills directly.
//   - Apple Intelligence (iOS 18+) can surface FERAL capabilities in
//     its system-level personal context.
//
// This file ships the App Shortcuts surface PLUS the CallKitSkill
// AppIntent. Phase 4b lands the rest (MusicKit, EventKit, Contacts,
// Location, Photos, Camera, Health, Notes, Screen).

/// Place a phone or FaceTime call. Mirrors `CallKitSkill`'s wire
/// surface so Siri/Shortcuts invocation lands on the same code.
@available(iOS 16.0, *)
public struct StartCallIntent: AppIntent {
    public static var title: LocalizedStringResource = "Call"
    public static var description = IntentDescription(
        "Place a phone or FaceTime call from your iPhone."
    )

    @Parameter(
        title: "Contact or number",
        description: "Phone number, FaceTime ID, or contact identifier."
    )
    public var contact: String

    @Parameter(
        title: "Video",
        description: "Use FaceTime video. Defaults to audio only."
    )
    public var video: Bool

    public init() {
        self.contact = ""
        self.video = false
    }

    public init(contact: String, video: Bool = false) {
        self.contact = contact
        self.video = video
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        let trimmed = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FeralSkillError.missingParameter("contact")
        }

        // Phone-number heuristic: digits + optional + and dashes.
        let isLikelyNumber = trimmed.allSatisfy {
            $0.isNumber || $0 == "+" || $0 == "-" || $0 == " " || $0 == "(" || $0 == ")"
        }
        let url = CallKitSkill.buildCallURL(
            number: isLikelyNumber ? trimmed : nil,
            facetimeID: isLikelyNumber ? nil : trimmed,
            video: video
        )
        guard let url, UIApplication.shared.canOpenURL(url) else {
            throw FeralSkillError.cannotOpen(url?.absoluteString ?? "(nil)")
        }

        _ = await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { ok in
                continuation.resume(returning: ok)
            }
        }

        return .result()
    }
}

/// Common error envelope so Phase 4b skills can reuse it. Operator's
/// truth-in-status rule applies: failures carry the specific
/// blocker, not a generic "something went wrong".
public enum FeralSkillError: Error, LocalizedError {
    case missingParameter(String)
    case cannotOpen(String)
    case permissionDenied(String)

    public var errorDescription: String? {
        switch self {
        case .missingParameter(let name):
            return "FERAL skill requires parameter `\(name)`."
        case .cannotOpen(let urlString):
            return "FERAL cannot open URL `\(urlString)` on this device."
        case .permissionDenied(let permission):
            return "FERAL needs `\(permission)` permission — grant via Settings."
        }
    }
}

/// `AppShortcutsProvider` registers a curated list of intents with
/// Siri / Shortcuts / Spotlight so they show up in the Shortcuts
/// app, Action Button picker, and Siri suggestions.
///
/// Phase 4a registers `StartCallIntent` to validate the registration
/// pattern. Phase 4b adds the rest.
@available(iOS 16.0, *)
public struct FeralAppShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartCallIntent(),
            phrases: [
                "Call \(.applicationName)",
                "Call someone with \(.applicationName)",
                "\(.applicationName) call",
            ],
            shortTitle: "Call",
            systemImageName: "phone.fill"
        )
    }
}
