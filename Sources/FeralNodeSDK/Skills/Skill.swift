import Foundation

// Phase 4 (audit-r10 overhaul plan) — Skill protocol + manifest.
//
// A `Skill` is a richer kind of `VendorAdapter`: alongside the
// `handleAction` dispatch surface it also publishes a structured
// manifest the brain can read at `node_register` time so the
// orchestrator + capability registry (Phase 5) know what the phone
// can actually do.
//
// Concretely: `CallKitSkill`, `MusicKitSkill`, `EventKitSkill`,
// `ContactsSkill`, `IntentsSkill`, `LocationSkill`, `PhotosSkill`,
// `CameraSnapSkill`, `ScreenSkill`, `HealthSkill`, `NotesSkill` —
// each is a Skill that registers on `FeralNode` via the same
// adapter slot the W300 / Theora glasses already use. The brain
// dispatches `phone.<skill>.<action>` HUP action names; the matching
// skill replies via `sendActionResponse`.
//
// `Skill` extends `VendorAdapter` instead of replacing it so the
// existing `FeralNode.handleAction` loop dispatches both kinds of
// adapter without a separate code path. The brain doesn't need to
// know the difference.

/// Manifest the brain reads to learn what a skill can do.
///
/// Sent in `node_register.skills` (Phase 4 wire field on
/// `NodeRegisterPayload`). The brain's capability registry (Phase 5)
/// merges this with the global skill manifests so `GET /api/capabilities`
/// returns the full union of brain-host + phone + glasses capabilities.
public struct SkillManifest: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let actions: [SkillActionManifest]

    public init(
        id: String,
        name: String,
        description: String,
        actions: [SkillActionManifest]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.actions = actions
    }
}

/// One action exposed by a skill. Maps 1:1 to a HUP
/// `hup_action_request.name` value the brain may dispatch.
public struct SkillActionManifest: Codable, Sendable, Equatable {
    public let name: String
    public let summary: String
    /// Optional iOS permission identifier (e.g. `"NSContactsUsageDescription"`,
    /// `"NSCameraUsageDescription"`). The unified `permission_card` flow
    /// (Phase 6) reads this when the skill returns a denial so the brain
    /// can surface a structured deeplink instead of a hallucinated
    /// "go to Settings" prose.
    public let requiresPermission: String?

    public init(name: String, summary: String, requiresPermission: String? = nil) {
        self.name = name
        self.summary = summary
        self.requiresPermission = requiresPermission
    }
}

/// Companion-side skill protocol.
///
/// Concrete skills (`CallKitSkill`, `MusicKitSkill`, etc.) live in the
/// app target because they depend on platform frameworks (CallKit,
/// MusicKit, EventKit) the SDK target cannot link. The protocol +
/// manifest types live HERE so any FeralNode consumer can reason
/// about skills without pulling in the iOS-specific dependencies.
public protocol Skill: VendorAdapter {
    /// Structured manifest published in `node_register.skills`. The
    /// brain reads `manifest.actions[*].name` to know which action
    /// names this skill handles + which iOS permission each requires.
    var manifest: SkillManifest { get }
}

/// Default `canHandleAction` implementation: match against the
/// manifest's action list. Skills with bespoke routing can override.
public extension Skill {
    func canHandleAction(named name: String) async -> Bool {
        manifest.actions.contains { $0.name == name }
    }
}
