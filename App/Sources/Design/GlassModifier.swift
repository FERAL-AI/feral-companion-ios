import SwiftUI

/// SwiftUI equivalent of `feral-client-v2/src/ui/Glass.jsx`.
///
/// Provides the frosted translucent panel that every FERAL surface uses.
/// Three levels mirror the CSS `v2-glass--level-{0,1,2}`:
///   - `.thin`  → ultraThinMaterial  (surface-0, lightest)
///   - `.regular` → thinMaterial     (surface-1, default)
///   - `.thick` → regularMaterial    (surface-2, elevated)
///
/// Usage:
///   ```
///   VStack { content }
///       .feralGlass()                         // default: regular, md radius
///       .feralGlass(.thick, radius: .lg)      // elevated panel
///   ```

struct FeralGlassModifier: ViewModifier {
    let level: GlassLevel
    let radius: GlassRadius

    func body(content: Content) -> some View {
        content
            .background(level.material, in: shape)
            .overlay(shape.stroke(FeralTheme.hairline, lineWidth: 0.5))
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius.value, style: .continuous)
    }
}

enum GlassLevel {
    case thin, regular, thick

    var material: Material {
        switch self {
        case .thin: return .ultraThinMaterial
        case .regular: return .thinMaterial
        case .thick: return .regularMaterial
        }
    }
}

enum GlassRadius {
    case xs, sm, md, lg

    var value: CGFloat {
        switch self {
        case .xs: return FeralTheme.radiusXS
        case .sm: return FeralTheme.radiusSM
        case .md: return FeralTheme.radiusMD
        case .lg: return FeralTheme.radiusLG
        }
    }
}

extension View {
    func feralGlass(_ level: GlassLevel = .regular, radius: GlassRadius = .md) -> some View {
        modifier(FeralGlassModifier(level: level, radius: radius))
    }
}

/// Convenience card modifier: glass + padding + vertical spacing.
struct FeralCardModifier: ViewModifier {
    let level: GlassLevel
    let radius: GlassRadius

    func body(content: Content) -> some View {
        content
            .padding(FeralTheme.padMD)
            .feralGlass(level, radius: radius)
    }
}

extension View {
    func feralCard(_ level: GlassLevel = .regular, radius: GlassRadius = .md) -> some View {
        modifier(FeralCardModifier(level: level, radius: radius))
    }
}
