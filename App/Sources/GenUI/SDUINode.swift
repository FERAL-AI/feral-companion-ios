import Foundation
import CoreGraphics

// Audit-r8 brief #04 — Phase 5 iOS GenUI.
//
// SDUI is the brain's server-driven UI vocabulary. The single source
// of truth for the type list and field names is
// `feral-client-v2/src/ui/SduiRenderer.jsx`; this file mirrors that
// vocabulary in Swift so the same JSON tree renders identically on
// the phone. The brain pushes a tree via `genui_push.payload.sdui`
// (`models/protocol.py:GenUIPushPayload`) and follow-up `sdui_patch`
// frames carry JSON-Patch deltas (subset: `replace`/`add`/`remove`).
//
// Companion-iOS interactions go back over the `genui_event` HUP
// frame routed by `api/server.py` 1771–1814 to `_handle_app_action`.
// The chat path (`ui_event`) is a different code path used by the
// dashboard; iOS must never use it from the GenUI surface.

/// JSON-side helpers — patch a decoded `Any` tree (dict/array of
/// JSON-compatible values) using the same JSON-Patch subset the web
/// renderer accepts. The decoded tree never touches `SDUINode` so a
/// patch can re-flow nested children without re-parsing.
enum SDUIJSON {

    /// Apply a list of JSON-Patch operations to a decoded JSON tree.
    /// Operations: `replace`, `add`, `remove`. Unknown ops or invalid
    /// paths are dropped silently (matching the JS renderer).
    static func applyPatches(_ tree: Any, patches: [[String: Any]]) -> Any {
        guard !patches.isEmpty else { return tree }
        var next: Any = deepCopy(tree)
        for patch in patches {
            guard let path = patch["path"] as? String else { continue }
            let op = (patch["op"] as? String) ?? "replace"
            let segments = splitPath(path)
            let value = patch["value"]
            do {
                switch op {
                case "replace": try setAt(&next, segments, value)
                case "add": try addAt(&next, segments, value)
                case "remove": try removeAt(&next, segments)
                default: continue
                }
            } catch {
                continue
            }
        }
        return next
    }

    enum PathSegment: Hashable {
        case key(String)
        case index(Int)
    }

    private static func splitPath(_ p: String) -> [PathSegment] {
        let trimmed = p.hasPrefix("/") ? String(p.dropFirst()) : p
        if trimmed.isEmpty { return [] }
        return trimmed.split(separator: "/").map { seg in
            let s = String(seg)
            if let i = Int(s) { return .index(i) }
            return .key(s)
        }
    }

    private static func deepCopy(_ v: Any) -> Any {
        if let d = v as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, vv) in d { out[k] = deepCopy(vv) }
            return out
        }
        if let a = v as? [Any] {
            return a.map { deepCopy($0) }
        }
        return v
    }

    /// Walk to parent, return parent + final-segment.
    private static func locate(_ tree: inout Any, _ segments: [PathSegment])
        throws -> (parent: Any, parentPath: [PathSegment], last: PathSegment)
    {
        guard let last = segments.last else {
            throw NSError(domain: "SDUI", code: 100)
        }
        let parentPath = Array(segments.dropLast())
        var parent: Any = tree
        for seg in parentPath {
            switch seg {
            case .key(let k):
                guard let dict = parent as? [String: Any], let next = dict[k] else {
                    throw NSError(domain: "SDUI", code: 101)
                }
                parent = next
            case .index(let i):
                guard let arr = parent as? [Any], i >= 0, i < arr.count else {
                    throw NSError(domain: "SDUI", code: 102)
                }
                parent = arr[i]
            }
        }
        return (parent, parentPath, last)
    }

    private static func writeBack(_ tree: inout Any, _ parentPath: [PathSegment], _ newParent: Any) throws {
        if parentPath.isEmpty {
            tree = newParent
            return
        }
        // Rebuild the chain by re-walking and replacing the final
        // step. Naive but the trees we deal with are tiny.
        var stack: [(Any, PathSegment)] = []
        var cur: Any = tree
        for seg in parentPath {
            switch seg {
            case .key(let k):
                guard let dict = cur as? [String: Any], let next = dict[k] else {
                    throw NSError(domain: "SDUI", code: 110)
                }
                stack.append((cur, seg))
                cur = next
            case .index(let i):
                guard let arr = cur as? [Any], i >= 0, i < arr.count else {
                    throw NSError(domain: "SDUI", code: 111)
                }
                stack.append((cur, seg))
                cur = arr[i]
            }
        }
        var current = newParent
        for (parent, seg) in stack.reversed() {
            switch seg {
            case .key(let k):
                guard var dict = parent as? [String: Any] else {
                    throw NSError(domain: "SDUI", code: 112)
                }
                dict[k] = current
                current = dict
            case .index(let i):
                guard var arr = parent as? [Any], i >= 0, i < arr.count else {
                    throw NSError(domain: "SDUI", code: 113)
                }
                arr[i] = current
                current = arr
            }
        }
        tree = current
    }

    private static func setAt(_ tree: inout Any, _ segments: [PathSegment], _ value: Any?) throws {
        if segments.isEmpty {
            if let v = value { tree = v }
            return
        }
        let (parent, parentPath, last) = try locate(&tree, segments)
        switch last {
        case .key(let k):
            guard var dict = parent as? [String: Any] else {
                throw NSError(domain: "SDUI", code: 200)
            }
            dict[k] = value as Any
            try writeBack(&tree, parentPath, dict)
        case .index(let i):
            guard var arr = parent as? [Any], i >= 0, i < arr.count else {
                throw NSError(domain: "SDUI", code: 201)
            }
            arr[i] = value as Any
            try writeBack(&tree, parentPath, arr)
        }
    }

    private static func addAt(_ tree: inout Any, _ segments: [PathSegment], _ value: Any?) throws {
        guard !segments.isEmpty else { return }
        let (parent, parentPath, last) = try locate(&tree, segments)
        switch last {
        case .key(let k):
            guard var dict = parent as? [String: Any] else {
                throw NSError(domain: "SDUI", code: 300)
            }
            dict[k] = value as Any
            try writeBack(&tree, parentPath, dict)
        case .index(let i):
            guard var arr = parent as? [Any] else {
                throw NSError(domain: "SDUI", code: 301)
            }
            if i == arr.count {
                arr.append(value as Any)
            } else if i >= 0 && i < arr.count {
                arr.insert(value as Any, at: i)
            } else {
                throw NSError(domain: "SDUI", code: 302)
            }
            try writeBack(&tree, parentPath, arr)
        }
    }

    private static func removeAt(_ tree: inout Any, _ segments: [PathSegment]) throws {
        guard !segments.isEmpty else { return }
        let (parent, parentPath, last) = try locate(&tree, segments)
        switch last {
        case .key(let k):
            guard var dict = parent as? [String: Any] else {
                throw NSError(domain: "SDUI", code: 400)
            }
            dict.removeValue(forKey: k)
            try writeBack(&tree, parentPath, dict)
        case .index(let i):
            guard var arr = parent as? [Any], i >= 0, i < arr.count else {
                throw NSError(domain: "SDUI", code: 401)
            }
            arr.remove(at: i)
            try writeBack(&tree, parentPath, arr)
        }
    }
}

/// Typed SDUI tree decoded from the brain's JSON. Every `type` string
/// in `feral-client-v2/src/ui/SduiRenderer.jsx` has a corresponding
/// case here so the SwiftUI renderer in `SDUIRenderer.swift` can
/// switch exhaustively. Unknown types become `.unknown(_)` so the
/// renderer can show a debug stub instead of crashing.
enum SDUINode: Equatable {
    case fragment([SDUINode])
    case text(String)

    case vStack(spacing: CGFloat, padding: CGFloat, testID: String?, children: [SDUINode])
    case hStack(spacing: CGFloat, padding: CGFloat, children: [SDUINode])
    case spacer(minHeight: CGFloat)
    case divider

    case textBlock(value: String, style: String?, colorHex: String?)
    case markdown(content: String)

    case image(url: String, alt: String, cornerRadius: CGFloat)
    case icon(name: String?, size: CGFloat, colorHex: String?)
    case badge(label: String, colorHex: String?, textColorHex: String?)

    case card(spacing: CGFloat, children: [SDUINode])
    case metricCard(label: String, value: String, unit: String?, colorHex: String?)

    case grid(columns: Int, spacing: CGFloat, children: [SDUINode])
    case scroll(maxHeight: CGFloat, spacing: CGFloat, padding: CGFloat, children: [SDUINode])
    case list(items: [SDUINode], spacing: CGFloat, emptyTitle: String, emptyHint: String, testID: String?)

    case tabs(items: [SDUITabItem], defaultTab: SDUITabID)
    case modal(open: Bool, title: String?, cancelActionID: String?, body: SDUINodeBox?)
    case accordion(sections: [SDUIAccordionSection], defaultOpen: Int?)

    case button(actionID: String, label: String, style: String, testID: String?, disabled: Bool, valueJSON: SDUIJSONValue?)
    case checkbox(actionID: String, label: String, value: Bool)
    case textField(actionID: String, label: String?, value: String, placeholder: String?, inputType: String, live: Bool)
    case slider(actionID: String, label: String?, min: Double, max: Double, step: Double, value: Double, live: Bool)
    case dateTimeInput(actionID: String, label: String?, value: String, mode: String)
    case multipleChoice(actionID: String, options: [SDUIMCOption], multi: Bool, selectionJSON: SDUIJSONValue?)
    case form(actionID: String, fields: [SDUIFormField], submitLabel: String, submitTestID: String?)

    case progressBar(label: String?, value: Double, colorHex: String?)
    case skeleton(lines: Int)

    /// Heavy/native-only components that the web renderer also stubs:
    /// `MapView`, `Chart`, `Table`, `WebView`, `MediaPlayer`, etc.
    case placeholder(kind: String, label: String?)

    /// Phase 6 (audit-r10 overhaul) — structured iOS permission denial.
    /// The brain emits this when a Phase 4 skill returns
    /// `permission_denied:<NSKey>`; the card carries pre-canned title /
    /// description / Settings deeplink copy sourced from
    /// `agents/permission_card.py:PERMISSION_CATALOG` so the LLM can't
    /// hallucinate a non-existent Settings path.
    case permissionCard(
        permissionKey: String,
        title: String,
        description: String,
        iosDeeplink: String,
        iosDeeplinkLabel: String,
        skillID: String?,
        action: String?,
        retryable: Bool
    )

    /// Type id we don't recognise. The renderer surfaces this as a
    /// dashed-border debug stub so the operator can see exactly what
    /// the brain sent that we don't know how to draw.
    case unknown(typeName: String)

    struct SDUITabItem: Equatable {
        var id: SDUITabID
        var label: String
        var actionID: String?
        var body: SDUINodeBox?
    }

    enum SDUITabID: Equatable, Hashable {
        case int(Int)
        case string(String)
    }

    struct SDUIAccordionSection: Equatable {
        var title: String
        var body: SDUINodeBox?
    }

    struct SDUIMCOption: Equatable {
        var id: String
        var label: String
    }

    enum SDUIFormField: Equatable {
        case text(name: String, label: String, value: String, placeholder: String?)
        case number(name: String, label: String, value: String, placeholder: String?)
        case checkbox(name: String, label: String, value: Bool)
        case select(name: String, label: String, value: String, options: [SDUIMCOption])
    }

    /// JSON value carried alongside a control's emitted action so the
    /// renderer can forward primitives without leaking `Any` through
    /// closures (Equatable required for diffable views).
    enum SDUIJSONValue: Equatable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case array([SDUIJSONValue])
        case object([String: SDUIJSONValue])
        case null

        /// Lossy re-export for the wire codec.
        func plain() -> Any {
            switch self {
            case .string(let s): return s
            case .int(let i): return i
            case .double(let d): return d
            case .bool(let b): return b
            case .null: return NSNull()
            case .array(let a): return a.map { $0.plain() }
            case .object(let o): return o.mapValues { $0.plain() }
            }
        }

        static func from(_ any: Any?) -> SDUIJSONValue? {
            guard let any else { return nil }
            if any is NSNull { return .null }
            if let s = any as? String { return .string(s) }
            if let b = any as? Bool {
                if let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
                    return .double(n.doubleValue)
                }
                return .bool(b)
            }
            if let i = any as? Int { return .int(i) }
            if let d = any as? Double { return .double(d) }
            if let n = any as? NSNumber {
                if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
                return .double(n.doubleValue)
            }
            if let arr = any as? [Any] { return .array(arr.compactMap { SDUIJSONValue.from($0) }) }
            if let dict = any as? [String: Any] {
                var out: [String: SDUIJSONValue] = [:]
                for (k, v) in dict { if let conv = SDUIJSONValue.from(v) { out[k] = conv } }
                return .object(out)
            }
            return nil
        }
    }

    /// Indirect box so recursive enum cases compile.
    indirect enum SDUINodeBox: Equatable {
        case some(SDUINode)
    }

    static func decode(_ any: Any) -> SDUINode? {
        if let s = any as? String { return .text(s) }
        if let n = any as? NSNumber {
            return .text(n.stringValue)
        }
        if let arr = any as? [Any] {
            return .fragment(arr.compactMap { decode($0) })
        }
        guard let obj = any as? [String: Any] else { return nil }
        let typeRaw = (obj["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if typeRaw.isEmpty { return nil }

        switch typeRaw {
        case "VStack", "Column":
            return .vStack(
                spacing: gapPx(obj["spacing"]),
                padding: padPx(obj["padding"]),
                testID: obj["testid"] as? String,
                children: decodeChildren(obj["children"])
            )
        case "HStack", "Row":
            return .hStack(
                spacing: gapPx(obj["spacing"]),
                padding: padPx(obj["padding"]),
                children: decodeChildren(obj["children"])
            )
        case "Spacer":
            let h = doubleKey(obj["height"]) ?? 0
            return .spacer(minHeight: CGFloat(h))
        case "Divider":
            return .divider
        case "Text":
            let val = (obj["value"] as? String) ?? stringifyJSON(obj["value"])
            return .textBlock(value: val, style: obj["style"] as? String, colorHex: obj["color"] as? String)
        case "Markdown":
            let c = (obj["content"] as? String) ?? (obj["value"] as? String) ?? ""
            return .markdown(content: c)
        case "Image", "AsyncImage":
            guard let url = obj["url"] as? String else { return .placeholder(kind: typeRaw, label: nil) }
            let alt = (obj["alt"] as? String) ?? ""
            let cr = doubleKey(obj["corner_radius"]) ?? 8
            return .image(url: url, alt: alt, cornerRadius: CGFloat(cr))
        case "Icon":
            let size = doubleKey(obj["size"]) ?? 16
            return .icon(name: obj["name"] as? String, size: CGFloat(size), colorHex: obj["color"] as? String)
        case "Badge":
            let label = (obj["label"] as? String) ?? stringifyJSON(obj["value"])
            return .badge(label: label, colorHex: obj["color"] as? String, textColorHex: obj["text_color"] as? String)
        case "Card":
            return .card(spacing: gapPx(obj["spacing"] ?? "sm"), children: decodeChildren(obj["children"]))
        case "MetricCard":
            return .metricCard(
                label: (obj["label"] as? String) ?? "",
                value: stringifyJSON(obj["value"]),
                unit: obj["unit"] as? String,
                colorHex: obj["color"] as? String
            )
        case "Grid":
            let cols = clamp(Int(doubleKey(obj["columns"]) ?? 2), 1, 6)
            return .grid(columns: cols, spacing: gapPx(obj["spacing"] ?? "sm"), children: decodeChildren(obj["children"]))
        case "ScrollView":
            let mh = doubleKey(obj["max_height"]) ?? 320
            return .scroll(
                maxHeight: CGFloat(mh),
                spacing: gapPx(obj["spacing"] ?? "sm"),
                padding: padPx(obj["padding"]),
                children: decodeChildren(obj["children"])
            )
        case "List":
            let itemsArr = obj["items"] as? [Any] ?? []
            let items = itemsArr.compactMap { decode($0) }
            return .list(
                items: items,
                spacing: gapPx(obj["spacing"] ?? "sm"),
                emptyTitle: (obj["empty_title"] as? String) ?? "Nothing here yet",
                emptyHint: (obj["empty_hint"] as? String) ?? "",
                testID: obj["testid"] as? String
            )
        case "Tabs":
            let rawItems = obj["items"] as? [[String: Any]] ?? []
            var tabs: [SDUITabItem] = []
            for (i, t) in rawItems.enumerated() {
                let id: SDUITabID
                if let s = t["id"] as? String { id = .string(s) }
                else if let ii = t["id"] as? Int { id = .int(ii) }
                else { id = .int(i) }
                let label = (t["label"] as? String) ?? stringifyJSON(t["id"])
                let aid = t["action_id"] as? String
                let body = decode(t["body"] as Any).map { SDUINodeBox.some($0) }
                tabs.append(SDUITabItem(id: id, label: label, actionID: aid, body: body))
            }
            let def: SDUITabID
            if let dt = obj["default_tab"] as? String { def = .string(dt) }
            else if let di = obj["default_tab"] as? Int { def = .int(di) }
            else if let first = tabs.first { def = first.id }
            else { def = .int(0) }
            return .tabs(items: tabs, defaultTab: def)
        case "Modal":
            let open = (obj["open"] as? Bool) ?? false
            let title = obj["title"] as? String
            let cancel = obj["cancel_action_id"] as? String
            let body = decode(obj["body"] as Any).map { SDUINodeBox.some($0) }
            return .modal(open: open, title: title, cancelActionID: cancel, body: body)
        case "Accordion", "AccordionView":
            let secs = obj["sections"] as? [[String: Any]] ?? []
            var out: [SDUIAccordionSection] = []
            for s in secs {
                let tit = (s["title"] as? String) ?? ""
                let b = decode(s["body"] as Any).map { SDUINodeBox.some($0) }
                out.append(SDUIAccordionSection(title: tit, body: b))
            }
            let defOpen = obj["default_open"] as? Int
            return .accordion(sections: out, defaultOpen: defOpen)
        case "Button":
            let aid = (obj["action_id"] as? String) ?? ""
            return .button(
                actionID: aid,
                label: (obj["label"] as? String) ?? stringifyJSON(obj["value"]),
                style: (obj["style"] as? String) ?? "default",
                testID: obj["testid"] as? String,
                disabled: (obj["disabled"] as? Bool) ?? false,
                valueJSON: SDUIJSONValue.from(obj["value"])
            )
        case "Checkbox":
            return .checkbox(
                actionID: (obj["action_id"] as? String) ?? "",
                label: (obj["label"] as? String) ?? "",
                value: (obj["value"] as? Bool) ?? false
            )
        case "TextField":
            return .textField(
                actionID: (obj["action_id"] as? String) ?? "",
                label: obj["label"] as? String,
                value: (obj["value"] as? String) ?? "",
                placeholder: obj["placeholder"] as? String,
                inputType: (obj["input_type"] as? String) ?? "text",
                live: (obj["live"] as? Bool) ?? false
            )
        case "Slider":
            let minV = doubleKey(obj["min"]) ?? 0
            let maxV = doubleKey(obj["max"]) ?? 100
            let step = doubleKey(obj["step"]) ?? 1
            let val = doubleKey(obj["value"]) ?? minV
            return .slider(
                actionID: (obj["action_id"] as? String) ?? "",
                label: obj["label"] as? String,
                min: minV,
                max: maxV,
                step: step,
                value: val,
                live: (obj["live"] as? Bool) ?? false
            )
        case "DateTimeInput":
            return .dateTimeInput(
                actionID: (obj["action_id"] as? String) ?? "",
                label: obj["label"] as? String,
                value: (obj["value"] as? String) ?? "",
                mode: (obj["mode"] as? String) ?? "datetime"
            )
        case "MultipleChoice":
            let opts = decodeMCOptions(obj["options"] as? [Any] ?? [])
            return .multipleChoice(
                actionID: (obj["action_id"] as? String) ?? "",
                options: opts,
                multi: (obj["multi"] as? Bool) ?? false,
                selectionJSON: SDUIJSONValue.from(obj["value"])
            )
        case "Form", "FormView":
            let fields = decodeFormFields(obj["fields"] as? [Any] ?? [])
            return .form(
                actionID: (obj["action_id"] as? String) ?? "",
                fields: fields,
                submitLabel: (obj["submit_label"] as? String) ?? "Submit",
                submitTestID: obj["submit_testid"] as? String
            )
        case "ProgressBar":
            let v = doubleKey(obj["value"]) ?? 0
            return .progressBar(label: obj["label"] as? String, value: v, colorHex: obj["color"] as? String)
        case "Skeleton":
            let lines = Int(doubleKey(obj["lines"]) ?? 3)
            return .skeleton(lines: max(1, lines))
        case "MapView", "GraphView", "Chart", "ChartView", "Table", "TableView",
             "WebView", "VideoPlayer", "AudioPlayer", "MediaPlayer", "CodeBlock":
            return .placeholder(kind: typeRaw, label: obj["label"] as? String)
        case "permission_card", "PermissionCard":
            // Phase 6 (audit-r10 overhaul). Shape sourced from
            // `agents/permission_card.py:build_permission_card`.
            return .permissionCard(
                permissionKey: (obj["permission_key"] as? String) ?? "",
                title: (obj["title"] as? String) ?? "FERAL needs a permission",
                description: (obj["description"] as? String) ?? "",
                iosDeeplink: (obj["ios_deeplink"] as? String) ?? "app-settings:",
                iosDeeplinkLabel: (obj["ios_deeplink_label"] as? String) ?? "Open Settings",
                skillID: obj["skill_id"] as? String,
                action: obj["action"] as? String,
                retryable: (obj["retryable"] as? Bool) ?? true
            )
        default:
            return .unknown(typeName: typeRaw)
        }
    }

    private static func decodeChildren(_ any: Any?) -> [SDUINode] {
        guard let any else { return [] }
        if let arr = any as? [Any] { return arr.compactMap { decode($0) } }
        if let node = decode(any) { return [node] }
        return []
    }

    private static func gapPx(_ spacing: Any?) -> CGFloat {
        let map: [String: CGFloat] = ["xs": 4, "sm": 6, "md": 8, "lg": 12, "xl": 16]
        if let n = spacing as? NSNumber { return CGFloat(truncating: n) }
        if let i = spacing as? Int { return CGFloat(i) }
        if let s = spacing as? String, let g = map[s] { return g }
        return 8
    }

    private static func padPx(_ padding: Any?) -> CGFloat {
        let map: [String: CGFloat] = ["xs": 4, "sm": 6, "md": 8, "lg": 12, "xl": 16]
        if let n = padding as? NSNumber { return CGFloat(truncating: n) }
        if let i = padding as? Int { return CGFloat(i) }
        if let s = padding as? String, let g = map[s] { return g }
        return 0
    }

    private static func doubleKey(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(v, lo), hi) }

    private static func stringifyJSON(_ v: Any?) -> String {
        guard let v else { return "" }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if let b = v as? Bool { return b ? "true" : "false" }
        return String(describing: v)
    }

    private static func decodeMCOptions(_ arr: [Any]) -> [SDUIMCOption] {
        var out: [SDUIMCOption] = []
        for el in arr {
            if let s = el as? String {
                out.append(SDUIMCOption(id: s, label: s))
            } else if let o = el as? [String: Any] {
                let id = stringifyJSON(o["id"])
                let label = (o["label"] as? String) ?? id
                out.append(SDUIMCOption(id: id, label: label))
            }
        }
        return out
    }

    private static func decodeFormFields(_ arr: [Any]) -> [SDUIFormField] {
        var out: [SDUIFormField] = []
        for el in arr {
            guard let f = el as? [String: Any] else { continue }
            let name = (f["name"] as? String) ?? ""
            let label = (f["label"] as? String) ?? name
            let typ = (f["type"] as? String) ?? "text"
            switch typ {
            case "checkbox":
                out.append(.checkbox(name: name, label: label, value: (f["value"] as? Bool) ?? false))
            case "select":
                let opts = decodeMCOptions(f["options"] as? [Any] ?? [])
                out.append(.select(name: name, label: label, value: (f["value"] as? String) ?? "", options: opts))
            case "number":
                out.append(.number(name: name, label: label, value: stringifyJSON(f["value"]), placeholder: f["placeholder"] as? String))
            default:
                out.append(.text(name: name, label: label, value: (f["value"] as? String) ?? "", placeholder: f["placeholder"] as? String))
            }
        }
        return out
    }
}
