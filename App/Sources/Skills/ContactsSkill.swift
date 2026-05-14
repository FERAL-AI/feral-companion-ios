import Contacts
import Foundation

// Phase 4b (audit-r10 overhaul) — ContactsSkill.
// Pairs with Phase 4a's CallKitSkill: the brain resolves
// "call John" → ContactsSkill.lookup → CallKitSkill.start, no more
// "I need a phone number" stalls.

@MainActor
public final class ContactsSkill: Skill {

    public let capability: String = "contacts"

    public let manifest = SkillManifest(
        id: "contacts",
        name: "Contacts",
        description:
            "Read the user's iOS Contacts. Returns matched contacts "
            + "with phone numbers, emails, and identifiers suitable "
            + "for chaining into `phone.call.start` (FaceTime / dial).",
        actions: [
            SkillActionManifest(
                name: "phone.contact.lookup",
                summary:
                    "Find contacts by name fragment. Params: "
                    + "{ query: string, limit?: int=10 }. Returns "
                    + "{ matches: [{name, phones:[...], emails:[...], "
                    + "facetime_ids:[...]}] }.",
                requiresPermission: "NSContactsUsageDescription"
            ),
        ]
    )

    private let store = CNContactStore()

    public init() {}

    public func attach(to node: FeralNode) async throws {}
    public func detach() async {}

    public func handleAction(frame: HUPFrame, node: FeralNode) async {
        guard case .string(let actionId) = frame.payload["action_id"] ?? .null else { return }

        let params: [String: AnyCodable]
        if case .object(let p) = frame.payload["params"] ?? .null { params = p } else { params = [:] }

        let query: String = {
            if case .string(let s) = params["query"] ?? .null { return s }
            return ""
        }()
        let limit: Int = {
            if case .int(let n) = params["limit"] ?? .null { return max(1, min(n, 50)) }
            return 10
        }()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try? await node.sendActionResponse(
                actionId: actionId, success: false,
                error: "phone.contact.lookup requires non-empty `query`"
            )
            return
        }

        // Permission probe — iOS 18 deprecates the sync auth-status
        // accessor in favour of the async one. Use the available API.
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .denied || status == .restricted {
            try? await node.sendActionResponse(
                actionId: actionId, success: false,
                error: "permission_denied:NSContactsUsageDescription"
            )
            return
        }
        if status == .notDetermined {
            let granted: Bool = await withCheckedContinuation { continuation in
                store.requestAccess(for: .contacts) { ok, _ in
                    continuation.resume(returning: ok)
                }
            }
            if !granted {
                try? await node.sendActionResponse(
                    actionId: actionId, success: false,
                    error: "permission_denied:NSContactsUsageDescription"
                )
                return
            }
        }

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey,
            CNContactInstantMessageAddressesKey,
        ].map { $0 as CNKeyDescriptor }

        let predicate = CNContact.predicateForContacts(matchingName: trimmed)
        let matches: [CNContact]
        do {
            matches = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
        } catch {
            try? await node.sendActionResponse(
                actionId: actionId, success: false,
                error: "phone.contact.lookup: \(error.localizedDescription)"
            )
            return
        }

        let trimmedMatches = matches.prefix(limit).map { Self.serialize(contact: $0) }
        try? await node.sendActionResponse(
            actionId: actionId, success: true,
            result: [
                "query": .string(trimmed),
                "matches": .array(trimmedMatches.map { .object($0) }),
                "count": .int(trimmedMatches.count),
            ]
        )
    }

    private static func serialize(contact: CNContact) -> [String: AnyCodable] {
        let phones = contact.phoneNumbers.map { (entry: CNLabeledValue<CNPhoneNumber>) -> AnyCodable in
            .object([
                "label": .string(entry.label ?? ""),
                "value": .string(entry.value.stringValue),
            ])
        }
        let emails = contact.emailAddresses.map { (entry: CNLabeledValue<NSString>) -> AnyCodable in
            .object([
                "label": .string(entry.label ?? ""),
                "value": .string(entry.value as String),
            ])
        }
        // FaceTime IDs are typically either a phone number or an
        // email — we surface emails as candidate facetime_ids so
        // the brain can hand them straight to `phone.call.start` with
        // `facetime_id=...`.
        let facetimeIDs: [AnyCodable] = contact.emailAddresses.map {
            .string($0.value as String)
        }

        let displayName = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return [
            "identifier": .string(contact.identifier),
            "name": .string(displayName),
            "phones": .array(phones),
            "emails": .array(emails),
            "facetime_ids": .array(facetimeIDs),
        ]
    }
}
