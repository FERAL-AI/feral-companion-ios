import EventKit
import Foundation

// Phase 4b (audit-r10 overhaul) — EventKitSkill.
// "What's on my schedule" + "add a meeting" demo path. Backed by
// EKEventStore so events appear in the real Calendar app.
//
// iOS 17 split calendar access into write-only and full; the skill
// always requests `requestFullAccessToEvents` because read is part
// of the contract (phone.event.list). `NSCalendarsFullAccessUsageDescription`
// is the required Info.plist key on iOS 17+; the legacy
// `NSCalendarsUsageDescription` is also present for back-compat.

@MainActor
public final class EventKitSkill: Skill {

    public let capability: String = "calendar"

    public let manifest = SkillManifest(
        id: "calendar",
        name: "Calendar",
        description:
            "Read and write events in the user's iOS Calendar via "
            + "EventKit. Events appear in the system Calendar app and "
            + "sync via iCloud where configured.",
        actions: [
            SkillActionManifest(
                name: "phone.event.list",
                summary:
                    "List upcoming events. Params: "
                    + "{ days_ahead?: int=7, limit?: int=20 }. "
                    + "Returns { events: [{title, start, end, "
                    + "location?, notes?}] }.",
                requiresPermission: "NSCalendarsFullAccessUsageDescription"
            ),
            SkillActionManifest(
                name: "phone.event.create",
                summary:
                    "Create an event on the user's default calendar. "
                    + "Params: { title: string, start: iso8601, "
                    + "end: iso8601, location?: string, notes?: string }.",
                requiresPermission: "NSCalendarsFullAccessUsageDescription"
            ),
        ]
    )

    private let store = EKEventStore()

    public init() {}

    public func attach(to node: FeralNode) async throws {}
    public func detach() async {}

    public func handleAction(frame: HUPFrame, node: FeralNode) async {
        guard case .string(let actionId) = frame.payload["action_id"] ?? .null else { return }
        guard case .string(let actionName) = frame.payload["name"] ?? .null else { return }

        let params: [String: AnyCodable]
        if case .object(let p) = frame.payload["params"] ?? .null { params = p } else { params = [:] }

        if let denial = await ensureCalendarAccess() {
            try? await node.sendActionResponse(
                actionId: actionId, success: false, error: denial
            )
            return
        }

        switch actionName {
        case "phone.event.list":
            await handleList(actionId: actionId, params: params, node: node)
        case "phone.event.create":
            await handleCreate(actionId: actionId, params: params, node: node)
        default:
            try? await node.sendActionResponse(
                actionId: actionId, success: false,
                error: "EventKitSkill: unknown action \(actionName)"
            )
        }
    }

    /// Returns `nil` on success, or a `permission_denied:<key>` token
    /// the brain can render as a permission card.
    private func ensureCalendarAccess() async -> String? {
        let status = EKEventStore.authorizationStatus(for: .event)
        // iOS 17 introduced `.fullAccess` / `.writeOnly` and deprecated
        // `.authorized`. Treat both `.fullAccess` (iOS 17+) and the
        // legacy `.authorized` (iOS 16) as success; `.writeOnly` is
        // insufficient because `phone.event.list` needs read.
        if #available(iOS 17.0, *) {
            switch status {
            case .fullAccess:
                return nil
            case .denied, .restricted, .writeOnly:
                return "permission_denied:NSCalendarsFullAccessUsageDescription"
            case .notDetermined:
                do {
                    let granted = try await store.requestFullAccessToEvents()
                    return granted ? nil : "permission_denied:NSCalendarsFullAccessUsageDescription"
                } catch {
                    return "phone.event: permission request failed: \(error.localizedDescription)"
                }
            @unknown default:
                return "permission_denied:NSCalendarsFullAccessUsageDescription"
            }
        } else {
            switch status {
            case .authorized:
                return nil
            case .denied, .restricted:
                return "permission_denied:NSCalendarsUsageDescription"
            case .notDetermined:
                let granted: Bool = await withCheckedContinuation { continuation in
                    store.requestAccess(to: .event) { ok, _ in
                        continuation.resume(returning: ok)
                    }
                }
                return granted ? nil : "permission_denied:NSCalendarsUsageDescription"
            @unknown default:
                return "permission_denied:NSCalendarsUsageDescription"
            }
        }
    }

    private func handleList(
        actionId: String,
        params: [String: AnyCodable],
        node: FeralNode
    ) async {
        let daysAhead: Int = {
            if case .int(let n) = params["days_ahead"] ?? .null { return max(1, min(n, 365)) }
            return 7
        }()
        let limit: Int = {
            if case .int(let n) = params["limit"] ?? .null { return max(1, min(n, 200)) }
            return 20
        }()

        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: daysAhead, to: start) ?? start
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let serialized: [AnyCodable] = events.map { event in
            var dict: [String: AnyCodable] = [
                "title": .string(event.title ?? ""),
                "start": .string(formatter.string(from: event.startDate)),
                "end": .string(formatter.string(from: event.endDate)),
                "all_day": .bool(event.isAllDay),
                "identifier": .string(event.eventIdentifier ?? ""),
            ]
            if let location = event.location, !location.isEmpty {
                dict["location"] = .string(location)
            }
            if let notes = event.notes, !notes.isEmpty {
                dict["notes"] = .string(notes)
            }
            return .object(dict)
        }

        try? await node.sendActionResponse(
            actionId: actionId, success: true,
            result: [
                "events": .array(serialized),
                "count": .int(serialized.count),
                "window_days": .int(daysAhead),
            ]
        )
    }

    private func handleCreate(
        actionId: String,
        params: [String: AnyCodable],
        node: FeralNode
    ) async {
        let title: String = {
            if case .string(let s) = params["title"] ?? .null { return s }
            return ""
        }()
        guard !title.isEmpty else {
            try? await node.sendActionResponse(
                actionId: actionId, success: false,
                error: "phone.event.create requires `title`"
            )
            return
        }

        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]

        let startStr: String = {
            if case .string(let s) = params["start"] ?? .null { return s }
            return ""
        }()
        let endStr: String = {
            if case .string(let s) = params["end"] ?? .null { return s }
            return ""
        }()
        guard let start = parser.date(from: startStr) else {
            try? await node.sendActionResponse(
                actionId: actionId, success: false,
                error: "phone.event.create: `start` must be ISO 8601 (got `\(startStr)`)"
            )
            return
        }
        guard let end = parser.date(from: endStr) else {
            try? await node.sendActionResponse(
                actionId: actionId, success: false,
                error: "phone.event.create: `end` must be ISO 8601 (got `\(endStr)`)"
            )
            return
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.calendar = store.defaultCalendarForNewEvents
        if case .string(let s) = params["location"] ?? .null, !s.isEmpty {
            event.location = s
        }
        if case .string(let s) = params["notes"] ?? .null, !s.isEmpty {
            event.notes = s
        }

        do {
            try store.save(event, span: .thisEvent, commit: true)
            try? await node.sendActionResponse(
                actionId: actionId, success: true,
                result: [
                    "event_id": .string(event.eventIdentifier ?? ""),
                    "title": .string(title),
                ]
            )
        } catch {
            try? await node.sendActionResponse(
                actionId: actionId, success: false,
                error: "phone.event.create: \(error.localizedDescription)"
            )
        }
    }
}
