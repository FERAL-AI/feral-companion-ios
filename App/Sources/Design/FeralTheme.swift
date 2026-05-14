import SwiftUI

/// Single source of truth for FERAL's visual language on iOS.
///
/// Mirrors `feral-client-v2/src/styles/tokens.css` to ensure visual parity
/// between the macOS web shell and this companion app. The aesthetic is
/// iOS 18+ glass/material — restrained, content-first, high contrast,
/// no sci-fi neon. Color appears only for real system state (live, warn,
/// error) or interactive focus.
///
/// Usage: `FeralTheme.surface1` / `FeralTheme.textPrimary` / etc.
/// View modifiers: `.feralGlass()` / `.feralCard()`

enum FeralTheme {

    // MARK: - Surfaces

    static let bgBase = Color(hex: 0x16161C)
    static let bgDeep = Color(hex: 0x0B0B10)

    static let surface0 = Color.white.opacity(0.04)
    static let surface1 = Color.white.opacity(0.07)
    static let surface2 = Color.white.opacity(0.12)
    static let surfaceElev = Color.white.opacity(0.18)

    static let hairline = Color.white.opacity(0.10)
    static let hairlineStrong = Color.white.opacity(0.18)

    // MARK: - Text

    static let textPrimary = Color(hex: 0xF5F5F7)
    static let textSecondary = Color(hex: 0xA1A1A8)
    static let textTertiary = Color(hex: 0x6E6E76)

    // MARK: - Accent (interactive only)

    static let accent = Color(hex: 0x0A84FF)
    static let accentSoft = Color(hex: 0x0A84FF).opacity(0.18)

    // MARK: - Semantic state (never decorative)

    static let stateLive = Color(hex: 0x30D158)
    static let stateLiveSoft = Color(hex: 0x30D158).opacity(0.18)
    static let stateWarn = Color(hex: 0xFFD60A)
    static let stateWarnSoft = Color(hex: 0xFFD60A).opacity(0.18)
    static let stateError = Color(hex: 0xFF453A)
    static let stateErrorSoft = Color(hex: 0xFF453A).opacity(0.18)

    // MARK: - Typography

    static let fontMono = Font.system(.body, design: .monospaced)
    static let fontMonoCaption = Font.system(.caption, design: .monospaced)

    // MARK: - Spacing

    static let radiusXS: CGFloat = 6
    static let radiusSM: CGFloat = 10
    static let radiusMD: CGFloat = 14
    static let radiusLG: CGFloat = 20

    static let padSM: CGFloat = 8
    static let padMD: CGFloat = 12
    static let padLG: CGFloat = 16
    static let padXL: CGFloat = 24

    // MARK: - Animation

    static let durFast: Double = 0.12
    static let durBase: Double = 0.18
    static let durSlow: Double = 0.32

    static let springSnappy = Animation.spring(response: 0.3, dampingFraction: 0.82)
    static let springGentle = Animation.spring(response: 0.5, dampingFraction: 0.78)
}

// MARK: - Color hex initializer

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
