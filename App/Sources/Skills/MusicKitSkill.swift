import Foundation
import MusicKit

// Phase 4b (audit-r10 overhaul) — MusicKitSkill.
// "Play Blinding Lights" demo path. Uses Apple's MusicKit SDK
// (iOS 15+) so the music actually plays through the system music
// player — visible in Now Playing widget, lock screen, AirPods
// double-tap, the whole stack.

@available(iOS 16.0, *)
@MainActor
public final class MusicKitSkill: Skill {

    public let capability: String = "music"

    public let manifest = SkillManifest(
        id: "music",
        name: "Apple Music",
        description:
            "Search and play songs from Apple Music on this iPhone "
            + "via MusicKit. Playback shows up in Now Playing, the "
            + "lock screen, and AirPods controls. Requires an "
            + "active Apple Music subscription for catalog playback; "
            + "library-only mode works without one.",
        actions: [
            SkillActionManifest(
                name: "phone.music.play",
                summary:
                    "Search Apple Music and play the top hit. Params: "
                    + "{ query: string }. Returns "
                    + "{ title, artist, song_id }.",
                requiresPermission: "NSAppleMusicUsageDescription"
            ),
            SkillActionManifest(
                name: "phone.music.pause",
                summary: "Pause the current Apple Music playback.",
                requiresPermission: "NSAppleMusicUsageDescription"
            ),
            SkillActionManifest(
                name: "phone.music.now_playing",
                summary:
                    "Return current Apple Music playback state. "
                    + "Returns { is_playing, title?, artist? }.",
                requiresPermission: nil
            ),
        ]
    )

    public init() {}

    public func attach(to node: FeralNode) async throws {}
    public func detach() async {}

    public func handleAction(frame: HUPFrame, node: FeralNode) async {
        guard case .string(let actionId) = frame.payload["action_id"] ?? .null else { return }
        guard case .string(let actionName) = frame.payload["name"] ?? .null else { return }

        let params: [String: AnyCodable]
        if case .object(let p) = frame.payload["params"] ?? .null { params = p } else { params = [:] }

        switch actionName {
        case "phone.music.play":
            await handlePlay(actionId: actionId, params: params, node: node)
        case "phone.music.pause":
            await handlePause(actionId: actionId, node: node)
        case "phone.music.now_playing":
            await handleNowPlaying(actionId: actionId, node: node)
        default:
            try? await node.sendActionResponse(
                actionId: actionId, success: false,
                error: "MusicKitSkill: unknown action \(actionName)"
            )
        }
    }

    private func handlePlay(
        actionId: String,
        params: [String: AnyCodable],
        node: FeralNode
    ) async {
        let query: String = {
            if case .string(let s) = params["query"] ?? .null { return s }
            return ""
        }()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try? await node.sendActionResponse(
                actionId: actionId, success: false,
                error: "phone.music.play requires non-empty `query`"
            )
            return
        }

        // MusicKit authorization is asynchronous + idempotent.
        let auth = await MusicAuthorization.request()
        guard auth == .authorized else {
            try? await node.sendActionResponse(
                actionId: actionId, success: false,
                error: "permission_denied:NSAppleMusicUsageDescription"
            )
            return
        }

        do {
            var request = MusicCatalogSearchRequest(term: trimmed, types: [Song.self])
            request.limit = 1
            let response = try await request.response()
            guard let song = response.songs.first else {
                try? await node.sendActionResponse(
                    actionId: actionId, success: false,
                    error: "phone.music.play: no Apple Music match for \"\(trimmed)\""
                )
                return
            }

            let player = ApplicationMusicPlayer.shared
            player.queue = [song]
            try await player.play()

            try? await node.sendActionResponse(
                actionId: actionId, success: true,
                result: [
                    "song_id": .string(song.id.rawValue),
                    "title": .string(song.title),
                    "artist": .string(song.artistName),
                ]
            )
        } catch {
            try? await node.sendActionResponse(
                actionId: actionId, success: false,
                error: "phone.music.play: \(error.localizedDescription)"
            )
        }
    }

    private func handlePause(actionId: String, node: FeralNode) async {
        ApplicationMusicPlayer.shared.pause()
        try? await node.sendActionResponse(
            actionId: actionId, success: true,
            result: ["paused": .bool(true)]
        )
    }

    private func handleNowPlaying(actionId: String, node: FeralNode) async {
        let player = ApplicationMusicPlayer.shared
        let isPlaying = player.state.playbackStatus == .playing
        var result: [String: AnyCodable] = [
            "is_playing": .bool(isPlaying),
        ]
        if let entry = player.queue.currentEntry {
            result["title"] = .string(entry.title ?? "")
            result["subtitle"] = .string(entry.subtitle ?? "")
        }
        try? await node.sendActionResponse(
            actionId: actionId, success: true, result: result
        )
    }
}
