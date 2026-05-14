import Foundation
import UIKit

// Phase 4 (audit-r10 overhaul plan) — CallKitSkill.
// FeralNodeSDK types (Skill, SkillManifest, FeralNode, HUPFrame,
// AnyCodable) live in the same compilation unit; no `import
// FeralNodeSDK` needed.
//
// Operator complaint #8:
//   "I asked the app to call my friend on my Mac and use facetime it
//    couldn't do that"
//
// Two halves to that ask:
//   - `device_target=brain` → AppleScript / `facetime://` URL on the
//     Mac (handled brain-side via the desktop_control skills now that
//     Phase 1 lifted the `phone_surface → http_api` deny).
//   - `device_target=phone` → THIS skill. Phone calls the contact
//     natively via CallKit / FaceTime URL scheme + reports back.
//
// This first cut uses the URL-scheme path because it does NOT require
// VoIP entitlements. CallKit's full provider integration (ringing
// UI, hold, Mute hold) ships in Phase 4b alongside background-VoIP
// permission handling. URL scheme is enough to make "call Mom" work
// from the phone right now.

@MainActor
public final class CallKitSkill: Skill {

    public let capability: String = "phone_call"

    public let manifest = SkillManifest(
        id: "phone_call",
        name: "Phone Call",
        description:
            "Place a phone or FaceTime call from the user's iPhone. "
            + "Uses the system dialer (`tel:`) or FaceTime URL "
            + "schemes (`facetime:` / `facetime-audio:`) so the call "
            + "appears in the standard Phone / FaceTime UI. Numbers "
            + "should be E.164-formatted when known.",
        actions: [
            SkillActionManifest(
                name: "phone.call.start",
                summary:
                    "Place a call. Params: { number?: string, "
                    + "facetime_id?: string, video?: bool }. At "
                    + "least one of number / facetime_id must be set. "
                    + "When video=true the FaceTime video URL is used; "
                    + "otherwise audio.",
                requiresPermission: nil  // URL schemes don't require runtime permissions
            ),
        ]
    )

    public init() {}

    public func attach(to node: FeralNode) async throws {
        // Nothing to wire — URL-scheme path has no persistent
        // subscriptions. Future CallKit integration would set up
        // CXProvider + CXCallController here.
    }

    public func detach() async {
        // Symmetric to attach: no resources held.
    }

    public func handleAction(frame: HUPFrame, node: FeralNode) async {
        guard case .string(let actionId) = frame.payload["action_id"] ?? .null else { return }

        // Params shape: { number?: string, facetime_id?: string, video?: bool }
        let params: [String: AnyCodable]
        if case .object(let p) = frame.payload["params"] ?? .null {
            params = p
        } else {
            params = [:]
        }

        let number: String? = {
            if case .string(let s) = params["number"] ?? .null, !s.isEmpty { return s }
            return nil
        }()
        let facetimeID: String? = {
            if case .string(let s) = params["facetime_id"] ?? .null, !s.isEmpty { return s }
            return nil
        }()
        let isVideo: Bool = {
            if case .bool(let b) = params["video"] ?? .null { return b }
            return false
        }()

        guard let url = Self.buildCallURL(number: number, facetimeID: facetimeID, video: isVideo) else {
            try? await node.sendActionResponse(
                actionId: actionId,
                success: false,
                error: "phone.call.start requires `number` or `facetime_id`"
            )
            return
        }

        // `UIApplication.shared.open` must run on the main actor.
        // Class is `@MainActor`-isolated so this call is already safe.
        let canOpen = UIApplication.shared.canOpenURL(url)
        guard canOpen else {
            try? await node.sendActionResponse(
                actionId: actionId,
                success: false,
                error:
                    "phone.call.start: device cannot open URL \(url.scheme ?? "?"). "
                    + "FaceTime / Phone may not be available on this device."
            )
            return
        }

        let opened: Bool = await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { ok in
                continuation.resume(returning: ok)
            }
        }

        if opened {
            try? await node.sendActionResponse(
                actionId: actionId,
                success: true,
                result: [
                    "scheme": .string(url.scheme ?? ""),
                    "target": .string(facetimeID ?? number ?? ""),
                    "video": .bool(isVideo),
                ]
            )
        } else {
            try? await node.sendActionResponse(
                actionId: actionId,
                success: false,
                error: "phone.call.start: UIApplication.open returned false"
            )
        }
    }

    /// Build a `tel:` / `facetime:` / `facetime-audio:` URL from the
    /// supplied params. Returns nil when neither identifier is given.
    /// Exposed for tests.
    static func buildCallURL(
        number: String?,
        facetimeID: String?,
        video: Bool
    ) -> URL? {
        let identifier = (facetimeID?.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? (number?.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let id = identifier, !id.isEmpty else { return nil }

        // URL-encode the identifier — emails contain `@` which is
        // valid in URL hosts but FaceTime IDs may include `+` from
        // E.164 numbers.
        guard let encoded = id.addingPercentEncoding(
            withAllowedCharacters: .urlPasswordAllowed
        ) else { return nil }

        // Scheme: facetime-audio / facetime / tel depending on intent.
        let scheme: String
        if facetimeID != nil {
            scheme = video ? "facetime" : "facetime-audio"
        } else {
            scheme = "tel"
        }
        return URL(string: "\(scheme):\(encoded)")
    }
}
