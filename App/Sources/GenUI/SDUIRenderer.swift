import SwiftUI

// Audit-r8 brief #04 — Phase 5 iOS GenUI renderer.
//
// Mirrors the JS renderer in `feral-client-v2/src/ui/SduiRenderer.jsx`
// component-for-component. The brain pushes a tree via `genui_push`;
// this view walks the typed `SDUINode` and emits SwiftUI. Every
// interactive control calls back through `onAction(eventType,
// actionId, value)` which the parent (BrainClient) must wire to
// `FeralNode.sendGenUIEvent` so the brain receives a `genui_event`.

/// Public entry point. Call sites:
///
/// ```swift
/// SDUIRenderer(tree: payload.sdui) { eventType, actionId, value in
///     Task { try? await node.sendGenUIEvent(...) }
/// }
/// ```
struct SDUIRenderer: View {
    let node: SDUINode
    let onAction: (String, String, SDUINode.SDUIJSONValue?) -> Void

    init(tree: Any, onAction: @escaping (String, String, SDUINode.SDUIJSONValue?) -> Void) {
        self.node = SDUINode.decode(tree) ?? .text("")
        self.onAction = onAction
    }

    var body: some View {
        SDUINodeView(node: node, onAction: onAction)
    }
}

private struct SDUINodeView: View {
    let node: SDUINode
    let onAction: (String, String, SDUINode.SDUIJSONValue?) -> Void

    var body: some View {
        switch node {
        case .fragment(let ch):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(ch.enumerated()), id: \.offset) { _, c in
                    SDUINodeView(node: c, onAction: onAction)
                }
            }
        case .text(let s):
            Text(s)

        case .vStack(let spacing, let padding, _, let children):
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, c in
                    SDUINodeView(node: c, onAction: onAction)
                }
            }
            .padding(padding)

        case .hStack(let spacing, let padding, let children):
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, c in
                    SDUINodeView(node: c, onAction: onAction)
                }
            }
            .padding(padding)

        case .spacer(let minH):
            Spacer(minLength: minH)

        case .divider:
            Divider()

        case .textBlock(let value, let style, let colorHex):
            Text(value)
                .font(font(for: style))
                .foregroundStyle(color(from: colorHex) ?? .primary)

        case .markdown(let content):
            Text(content)
                .font(.body)
                .multilineTextAlignment(.leading)

        case .image(let url, let alt, let cornerRadius):
            AsyncImage(url: URL(string: url)) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFit()
                case .failure:
                    Text(alt.isEmpty ? "Image" : alt).foregroundStyle(.secondary)
                case .empty:
                    ProgressView()
                @unknown default:
                    ProgressView()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityLabel(Text(alt))

        case .icon(let name, let size, let colorHex):
            Circle()
                .fill(color(from: colorHex) ?? Color.secondary.opacity(0.5))
                .frame(width: size, height: size)
                .accessibilityLabel(Text(name ?? "icon"))

        case .badge(let label, let colorHex, let textColorHex):
            Text(label)
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(color(from: colorHex) ?? Color.secondary.opacity(0.2))
                .foregroundStyle(color(from: textColorHex) ?? .primary)
                .clipShape(Capsule())

        case .card(let spacing, let children):
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, c in
                    SDUINodeView(node: c, onAction: onAction)
                }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )

        case .metricCard(let label, let value, let unit, let colorHex):
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value).font(.title2.weight(.semibold))
                        .foregroundStyle(color(from: colorHex) ?? .primary)
                    if let u = unit, !u.isEmpty {
                        Text(u).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        case .grid(let columns, let spacing, let children):
            let cols = Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns)
            LazyVGrid(columns: cols, spacing: spacing) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, c in
                    SDUINodeView(node: c, onAction: onAction)
                }
            }

        case .scroll(let maxHeight, let spacing, let padding, let children):
            ScrollView {
                VStack(alignment: .leading, spacing: spacing) {
                    ForEach(Array(children.enumerated()), id: \.offset) { _, c in
                        SDUINodeView(node: c, onAction: onAction)
                    }
                }
                .padding(padding)
            }
            .frame(maxHeight: maxHeight)

        case .list(let items, let spacing, let emptyTitle, let emptyHint, _):
            VStack(alignment: .leading, spacing: spacing) {
                if items.isEmpty {
                    Text(emptyTitle).font(.headline)
                    if !emptyHint.isEmpty {
                        Text(emptyHint).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, c in
                        SDUINodeView(node: c, onAction: onAction)
                    }
                }
            }

        case .tabs(let items, let defaultTab):
            SDUITabsView(items: items, defaultTab: defaultTab, onAction: onAction)

        case .modal(let open, let title, let cancelActionID, let body):
            SDUIModalView(open: open, title: title, cancelActionID: cancelActionID, bodyTree: body, onAction: onAction)

        case .accordion(let sections, let defaultOpen):
            SDUIAccordionView(sections: sections, defaultOpen: defaultOpen, onAction: onAction)

        case .button(let actionID, let label, let style, _, let disabled, let valueJSON):
            Button {
                guard !actionID.isEmpty else { return }
                onAction("tap", actionID, valueJSON)
            } label: {
                Text(label)
            }
            .buttonStyle(SDUIButtonStyle(kind: style))
            .disabled(disabled || actionID.isEmpty)

        case .checkbox(let actionID, let label, let value):
            SDUICheckboxView(actionID: actionID, label: label, initial: value, onAction: onAction)

        case .textField(let actionID, let label, let value, let placeholder, let inputType, let live):
            SDUITextFieldView(
                actionID: actionID, label: label, initial: value,
                placeholder: placeholder, inputType: inputType, live: live,
                onAction: onAction
            )

        case .slider(let actionID, let label, let min, let max, let step, let value, let live):
            SDUISliderView(
                actionID: actionID, label: label, min: min, max: max,
                step: step, initial: value, live: live, onAction: onAction
            )

        case .dateTimeInput(let actionID, let label, let value, let mode):
            SDUIDateTimeView(actionID: actionID, label: label, initial: value, mode: mode, onAction: onAction)

        case .multipleChoice(let actionID, let options, let multi, let selectionJSON):
            SDUIMultipleChoiceView(
                actionID: actionID, options: options, multi: multi,
                initial: selectionJSON, onAction: onAction
            )

        case .form(let actionID, let fields, let submitLabel, _):
            SDUIFormView(actionID: actionID, fields: fields, submitLabel: submitLabel, onAction: onAction)

        case .progressBar(let label, let value, let colorHex):
            VStack(alignment: .leading, spacing: 4) {
                if let label, !label.isEmpty {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
                ProgressView(value: min(max(value, 0), 1))
                    .tint(color(from: colorHex) ?? .accentColor)
            }

        case .skeleton(let lines):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<lines, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 10)
                        .frame(maxWidth: .infinity)
                        .padding(.trailing, CGFloat((i % 3) * 10))
                }
            }
            .accessibilityHidden(true)

        case .placeholder(let kind, let label):
            VStack(alignment: .leading, spacing: 4) {
                Text(kind).font(.caption.weight(.semibold))
                if let label, !label.isEmpty { Text(label).font(.caption2).foregroundStyle(.secondary) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary.opacity(0.4))
            )

        case .unknown(let typeName):
            Text("Unknown SDUI component: \(typeName)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.orange.opacity(0.5), lineWidth: 1)
                )
        }
    }

    private func font(for style: String?) -> Font {
        switch style {
        case "headline": return .headline
        case "subtitle": return .subheadline.weight(.semibold)
        case "caption": return .caption
        case "body": return .body
        default: return .body
        }
    }

    private func color(from hex: String?) -> Color? {
        guard let hex, hex.hasPrefix("#"), hex.count >= 7 else { return nil }
        let start = hex.index(hex.startIndex, offsetBy: 1)
        let r = Int(hex[start..<hex.index(start, offsetBy: 2)], radix: 16) ?? 0
        let g = Int(hex[hex.index(start, offsetBy: 2)..<hex.index(start, offsetBy: 4)], radix: 16) ?? 0
        let b = Int(hex[hex.index(start, offsetBy: 4)..<hex.index(start, offsetBy: 6)], radix: 16) ?? 0
        return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}

// MARK: - Subviews (state-bearing controls split out so each owns its
// own @State; the recursive renderer above stays a value type).

private struct SDUITabsView: View {
    let items: [SDUINode.SDUITabItem]
    let defaultTab: SDUINode.SDUITabID
    let onAction: (String, String, SDUINode.SDUIJSONValue?) -> Void

    @State private var active: SDUINode.SDUITabID

    init(items: [SDUINode.SDUITabItem], defaultTab: SDUINode.SDUITabID,
         onAction: @escaping (String, String, SDUINode.SDUIJSONValue?) -> Void)
    {
        self.items = items
        self.defaultTab = defaultTab
        self.onAction = onAction
        _active = State(initialValue: defaultTab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, t in
                        Button {
                            active = t.id
                            if let aid = t.actionID, !aid.isEmpty {
                                onAction("tap", aid, nil)
                            }
                        } label: {
                            Text(t.label)
                                .font(.subheadline.weight(t.id == active ? .semibold : .regular))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(
                                    t.id == active ? Color.accentColor.opacity(0.2) : Color.clear,
                                    in: Capsule()
                                )
                        }
                    }
                }
            }
            if let t = items.first(where: { $0.id == active }), case .some(let body)? = t.body {
                SDUINodeView(node: body, onAction: onAction)
            }
        }
    }
}

private struct SDUIModalView: View {
    let open: Bool
    let title: String?
    let cancelActionID: String?
    let bodyTree: SDUINode.SDUINodeBox?
    let onAction: (String, String, SDUINode.SDUIJSONValue?) -> Void

    var body: some View {
        Group {
            if open {
                ZStack {
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()
                        .onTapGesture {
                            let aid = cancelActionID ?? "modal_close"
                            onAction("tap", aid, nil)
                        }
                    VStack(alignment: .leading, spacing: 10) {
                        if let title, !title.isEmpty { Text(title).font(.headline) }
                        if case .some(let b)? = bodyTree {
                            SDUINodeView(node: b, onAction: onAction)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 480)
                    .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }
}

private struct SDUIAccordionView: View {
    let sections: [SDUINode.SDUIAccordionSection]
    let defaultOpen: Int?
    let onAction: (String, String, SDUINode.SDUIJSONValue?) -> Void

    @State private var openIdx: Int?

    init(sections: [SDUINode.SDUIAccordionSection], defaultOpen: Int?,
         onAction: @escaping (String, String, SDUINode.SDUIJSONValue?) -> Void)
    {
        self.sections = sections
        self.defaultOpen = defaultOpen
        self.onAction = onAction
        _openIdx = State(initialValue: defaultOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.offset) { i, s in
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        openIdx = (openIdx == i) ? nil : i
                    } label: {
                        Text(s.title)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                    if openIdx == i, case .some(let b)? = s.body {
                        SDUINodeView(node: b, onAction: onAction)
                            .padding(.bottom, 10)
                    }
                    Divider().opacity(0.3)
                }
            }
        }
    }
}

private struct SDUICheckboxView: View {
    let actionID: String
    let label: String
    let initial: Bool
    let onAction: (String, String, SDUINode.SDUIJSONValue?) -> Void

    @State private var checked: Bool

    init(actionID: String, label: String, initial: Bool,
         onAction: @escaping (String, String, SDUINode.SDUIJSONValue?) -> Void)
    {
        self.actionID = actionID
        self.label = label
        self.initial = initial
        self.onAction = onAction
        _checked = State(initialValue: initial)
    }

    var body: some View {
        Toggle(isOn: $checked) { Text(label) }
            .onChange(of: checked) { newVal in
                guard !actionID.isEmpty else { return }
                onAction("toggle", actionID, .bool(newVal))
            }
    }
}

private struct SDUITextFieldView: View {
    let actionID: String
    let label: String?
    let initial: String
    let placeholder: String?
    let inputType: String
    let live: Bool
    let onAction: (String, String, SDUINode.SDUIJSONValue?) -> Void

    @State private var text: String

    init(actionID: String, label: String?, initial: String, placeholder: String?,
         inputType: String, live: Bool,
         onAction: @escaping (String, String, SDUINode.SDUIJSONValue?) -> Void)
    {
        self.actionID = actionID
        self.label = label
        self.initial = initial
        self.placeholder = placeholder
        self.inputType = inputType
        self.live = live
        self.onAction = onAction
        _text = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label, !label.isEmpty {
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            TextField(placeholder ?? "", text: $text)
                .textFieldStyle(.roundedBorder)
                .keyboardType(inputType == "number" ? .decimalPad : .default)
                .onChange(of: text) { newVal in
                    guard !actionID.isEmpty, live else { return }
                    onAction("text_input", actionID, .string(newVal))
                }
                .onSubmit {
                    guard !actionID.isEmpty, !live else { return }
                    onAction("text_input", actionID, .string(text))
                }
        }
    }
}

private struct SDUISliderView: View {
    let actionID: String
    let label: String?
    let min: Double
    let max: Double
    let step: Double
    let initial: Double
    let live: Bool
    let onAction: (String, String, SDUINode.SDUIJSONValue?) -> Void

    @State private var val: Double

    init(actionID: String, label: String?, min: Double, max: Double, step: Double,
         initial: Double, live: Bool,
         onAction: @escaping (String, String, SDUINode.SDUIJSONValue?) -> Void)
    {
        self.actionID = actionID
        self.label = label
        self.min = min
        self.max = max
        self.step = step
        self.initial = initial
        self.live = live
        self.onAction = onAction
        _val = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label, !label.isEmpty {
                Text("\(label): \(Int(val))").font(.caption).foregroundStyle(.secondary)
            }
            Slider(value: $val, in: min...max, step: step, onEditingChanged: { editing in
                if !editing && !live && !actionID.isEmpty {
                    onAction("slider", actionID, .double(val))
                }
            })
            .onChange(of: val) { newVal in
                guard !actionID.isEmpty, live else { return }
                onAction("slider", actionID, .double(newVal))
            }
        }
    }
}

private struct SDUIDateTimeView: View {
    let actionID: String
    let label: String?
    let initial: String
    let mode: String
    let onAction: (String, String, SDUINode.SDUIJSONValue?) -> Void

    @State private var text: String

    init(actionID: String, label: String?, initial: String, mode: String,
         onAction: @escaping (String, String, SDUINode.SDUIJSONValue?) -> Void)
    {
        self.actionID = actionID
        self.label = label
        self.initial = initial
        self.mode = mode
        self.onAction = onAction
        _text = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label, !label.isEmpty {
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .onChange(of: text) { newVal in
                    guard !actionID.isEmpty else { return }
                    onAction("text_input", actionID, .string(newVal))
                }
        }
    }
}

private struct SDUIMultipleChoiceView: View {
    let actionID: String
    let options: [SDUINode.SDUIMCOption]
    let multi: Bool
    let initial: SDUINode.SDUIJSONValue?
    let onAction: (String, String, SDUINode.SDUIJSONValue?) -> Void

    @State private var single: String?
    @State private var multiSet: Set<String>

    init(actionID: String, options: [SDUINode.SDUIMCOption], multi: Bool,
         initial: SDUINode.SDUIJSONValue?,
         onAction: @escaping (String, String, SDUINode.SDUIJSONValue?) -> Void)
    {
        self.actionID = actionID
        self.options = options
        self.multi = multi
        self.initial = initial
        self.onAction = onAction
        if multi, case .array(let arr)? = initial {
            let strs = arr.compactMap { v -> String? in
                if case .string(let s) = v { return s }
                if case .int(let i) = v { return String(i) }
                return nil
            }
            _multiSet = State(initialValue: Set(strs))
            _single = State(initialValue: nil)
        } else if case .string(let s)? = initial {
            _single = State(initialValue: s)
            _multiSet = State(initialValue: [])
        } else {
            _single = State(initialValue: nil)
            _multiSet = State(initialValue: [])
        }
    }

    var body: some View {
        SDUIFlowLayout(spacing: 6) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let selected = multi ? multiSet.contains(opt.id) : single == opt.id
                Button {
                    if multi {
                        if multiSet.contains(opt.id) { multiSet.remove(opt.id) }
                        else { multiSet.insert(opt.id) }
                        guard !actionID.isEmpty else { return }
                        onAction("tap", actionID, .array(multiSet.map { .string($0) }))
                    } else {
                        single = opt.id
                        guard !actionID.isEmpty else { return }
                        onAction("tap", actionID, .string(opt.id))
                    }
                } label: {
                    Text(opt.label)
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(
                            selected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12),
                            in: Capsule()
                        )
                }
            }
        }
    }
}

private struct SDUIFormView: View {
    let actionID: String
    let fields: [SDUINode.SDUIFormField]
    let submitLabel: String
    let onAction: (String, String, SDUINode.SDUIJSONValue?) -> Void

    @State private var values: [String: SDUINode.SDUIJSONValue] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                fieldView(field)
            }
            Button(submitLabel) {
                guard !actionID.isEmpty else { return }
                onAction("tap", actionID, .object(["values": .object(values)]))
            }
            .buttonStyle(.borderedProminent)
        }
        .onAppear { seedDefaults() }
    }

    @ViewBuilder
    private func fieldView(_ field: SDUINode.SDUIFormField) -> some View {
        switch field {
        case .text(let name, let label, let value, let placeholder):
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                TextField(placeholder ?? "", text: textBinding(name, default: value))
                    .textFieldStyle(.roundedBorder)
            }
        case .number(let name, let label, let value, let placeholder):
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                TextField(placeholder ?? "", text: textBinding(name, default: value))
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
            }
        case .checkbox(let name, let label, let value):
            Toggle(isOn: boolBinding(name, default: value)) { Text(label) }
        case .select(let name, let label, let value, let options):
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Picker(label, selection: textBinding(name, default: value)) {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                        Text(o.label).tag(o.id)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private func seedDefaults() {
        guard values.isEmpty else { return }
        for f in fields {
            switch f {
            case .text(let n, _, let v, _): values[n] = .string(v)
            case .number(let n, _, let v, _): values[n] = .string(v)
            case .checkbox(let n, _, let v): values[n] = .bool(v)
            case .select(let n, _, let v, _): values[n] = .string(v)
            }
        }
    }

    private func textBinding(_ name: String, default def: String) -> Binding<String> {
        Binding(
            get: {
                if case .string(let s)? = values[name] { return s }
                return def
            },
            set: { values[name] = .string($0) }
        )
    }

    private func boolBinding(_ name: String, default def: Bool) -> Binding<Bool> {
        Binding(
            get: {
                if case .bool(let b)? = values[name] { return b }
                return def
            },
            set: { values[name] = .bool($0) }
        )
    }
}

private struct SDUIButtonStyle: ButtonStyle {
    let kind: String
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(foreground)
    }
    private func background(pressed: Bool) -> Color {
        let base: Color
        switch kind {
        case "primary": base = .accentColor
        case "danger": base = .red
        case "ghost": base = Color.secondary.opacity(0.15)
        case "secondary": base = Color.secondary.opacity(0.25)
        default: base = Color.secondary.opacity(0.2)
        }
        return pressed ? base.opacity(0.75) : base
    }
    private var foreground: Color {
        switch kind {
        case "primary", "danger": return .white
        default: return .primary
        }
    }
}

/// Minimal flow layout for chip rows (iOS 16+).
private struct SDUIFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ())
    {
        let arr = arrange(proposal: proposal, subviews: subviews)
        for (i, pos) in arr.positions.enumerated() {
            subviews[i].place(
                at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y),
                proposal: ProposedViewSize(arr.sizes[i])
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews)
        -> (size: CGSize, positions: [CGPoint], sizes: [CGSize])
    {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        var positions: [CGPoint] = []
        var sizes: [CGSize] = []
        let maxW = proposal.width ?? .infinity
        for sub in subviews {
            let sz = sub.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            positions.append(CGPoint(x: x, y: y))
            sizes.append(sz)
            rowH = max(rowH, sz.height)
            x += sz.width + spacing
        }
        let totalH = y + rowH
        let totalW = min(maxW, x)
        return (CGSize(width: totalW, height: totalH), positions, sizes)
    }
}
