import Foundation

/// Classifies inbound assistant text so internal tool-call envelopes
/// and tool-execution status lines never render as chat bubbles.
///
/// Parity note (the reason this exists): the WebUI (`feral-client-v2`,
/// `src/pages/Chat.jsx`) consumes the *same* brain WebSocket frames as
/// this app, but it routes `tool_start` / `tool_call` / `skill_start`
/// / `tool_result` frames into a collapsible `ToolCallCard` and NEVER
/// prints the raw `args_preview` JSON
/// (e.g. `{"script": "tell application \"Music\" to activate"}`) or the
/// brain's internal `"Running <skill>."` progress line as
/// conversational text. iOS only renders `chat_response` /
/// `text_response` / `transcript` frames, so when one of those frames
/// happens to carry a tool envelope or a status line (notably on the
/// realtime-voice path, where progress feedback is delivered as an
/// assistant `transcript` frame), it used to surface as a raw chat
/// bubble. This filter is the iOS-side equivalent of the WebUI's
/// "tool activity is not prose" rule: it suppresses those artifacts at
/// ingest so they never enter (or persist into) the transcript.
///
/// Deliberately narrow: it only suppresses recognized internal residue
/// and is only ever applied to assistant/system text — user-spoken or
/// user-typed text is never filtered, so we can never drop what the
/// user actually said.
enum TranscriptArtifactFilter {

    /// Top-level JSON keys that mark an object as an internal
    /// tool/command envelope rather than user-facing prose. Mirrors the
    /// shapes the brain builds in
    /// `agents/refusal_handler.build_action_intent_tool_call`
    /// (`{"script": ...}` / `{"command": ...}`) and the generic
    /// tool-call argument echoes (`args` / `arguments` / `tool` …).
    private static let envelopeKeys: Set<String> = [
        "script", "command", "tool", "tool_call", "tool_calls",
        "args", "arguments",
    ]

    /// `true` when `text` is an internal artifact that should be
    /// suppressed from the chat transcript.
    ///
    /// Callers MUST only pass assistant/system text here.
    static func isInternalArtifact(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if isToolEnvelopeJSON(trimmed) { return true }
        if isToolStatusLine(trimmed) { return true }
        return false
    }

    /// Detects a raw tool-call payload: a JSON object literal whose
    /// top-level keys include a known internal envelope key.
    ///
    /// Robust to the brain's `args_preview` truncation
    /// (`json.dumps(args)[:160]` in `orchestrator._emit_tool_start`):
    /// when the JSON is cut mid-value and no longer parses, we fall
    /// back to a quoted-key probe so a half-serialized
    /// `{"script": "tell application …` is still recognized.
    static func isToolEnvelopeJSON(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("{") else { return false }

        if trimmed.hasSuffix("}"),
           let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let dict = obj as? [String: Any] {
            return dict.keys.contains { envelopeKeys.contains($0) }
        }

        // Truncated / non-strict JSON fallback: starts like an object
        // and opens with a recognized envelope key.
        let probe = #"^\{\s*"(script|command|tool|tool_call|tool_calls|args|arguments)"\s*:"#
        return trimmed.range(of: probe, options: .regularExpression) != nil
    }

    /// Detects the brain's internal tool-execution status lines from
    /// `agents/tool_display.tool_feedback_text` — e.g. "Running open
    /// app.", "Running a command on your computer." These are
    /// spoken-progress affordances, not conversation; the WebUI shows
    /// the same information as a tool chip instead of a bubble.
    ///
    /// Kept tight (short, single status line ending in a period) so a
    /// genuine assistant sentence that merely begins with "Running" is
    /// not swept up.
    static func isToolStatusLine(_ trimmed: String) -> Bool {
        guard trimmed.count <= 60 else { return false }
        return trimmed.range(
            of: #"^Running\s+\S.*\.$"#,
            options: .regularExpression
        ) != nil
    }
}
