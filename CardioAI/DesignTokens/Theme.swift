//  Theme.swift
//  Design tokens ported from cardioai-ios (colors, typography, spacing, radius).
//  NOTE: Color(hex:) already lives in Services/Health/HealthKitService.swift — do not redefine here.

import SwiftUI
import UIKit

// MARK: - Colors

enum ColorPalette {

    // Brand
    static let primary   = Color.blue
    static let secondary = Color.purple
    static let accent    = Color.indigo

    // Semantic
    static let success = Color.green
    static let warning = Color.orange
    static let error   = Color.red
    static let info    = Color.blue

    // Vitals
    static let heartRate     = Color.red
    static let bloodPressure = Color.blue
    static let oxygen        = Color.cyan
    static let temperature   = Color.orange
    static let steps         = Color.green

    // Surface
    static let background        = Color(.systemBackground)
    static let groupedBackground = Color(.systemGroupedBackground)
    static let card              = Color(.systemBackground)
    static let inputBorder       = Color.gray.opacity(0.2)
    static let screenBackground  = Color(red: 0.957, green: 0.965, blue: 0.984)
    static let cardBackground    = Color.white

    // Text
    static let textPrimary   = Color.primary
    static let textSecondary = Color.secondary
    static let textOnPrimary = Color.white

    // Ink
    static let ink     = Color(red: 0.043, green: 0.071, blue: 0.125)
    static let inkSoft = Color(red: 0.357, green: 0.392, blue: 0.471)
    static let inkMute = Color(red: 0.612, green: 0.639, blue: 0.686)

    // Brand Blue
    static let brandBlue = Color(red: 0.118, green: 0.435, blue: 1.0)
    static let blueDark  = Color(red: 0.043, green: 0.310, blue: 0.800)
    static let blueSoft  = Color(red: 0.910, green: 0.941, blue: 1.0)
    static let blueTint  = Color(red: 0.949, green: 0.965, blue: 1.0)

    // Status
    static let cardioRed    = Color(red: 0.937, green: 0.267, blue: 0.267)
    static let redSoft      = Color(red: 0.996, green: 0.906, blue: 0.906)
    static let cardioAmber  = Color(red: 0.961, green: 0.620, blue: 0.043)
    static let amberSoft    = Color(red: 1.0,   green: 0.957, blue: 0.878)
    static let cardioGreen  = Color(red: 0.086, green: 0.639, blue: 0.290)
    static let greenSoft    = Color(red: 0.898, green: 0.969, blue: 0.925)
    static let cardioPurple = Color(red: 0.659, green: 0.333, blue: 0.969)
    static let purpleSoft   = Color(red: 0.961, green: 0.910, blue: 1.0)

    // Accent
    static let statusModerate = Color(red: 0.984, green: 0.749, blue: 0.141)
    static let liveGreen      = Color(red: 0.204, green: 0.831, blue: 0.600)

    // Vital tints (soft icon backgrounds, from Onboarding mockup)
    static let glucose      = Color(red: 0.961, green: 0.620, blue: 0.043) // #F59E0B
    static let glucoseSoft  = Color(red: 1.0,   green: 0.945, blue: 0.855) // #FFF1DA
    static let oxygenCyan   = Color(red: 0.024, green: 0.714, blue: 0.831) // #06B6D4
    static let oxygenSoft   = Color(red: 0.839, green: 0.957, blue: 0.980) // #D6F4FA

    // Divider
    static let line = Color(red: 0.933, green: 0.945, blue: 0.965)

    // Gradients
    static let brandGradient = LinearGradient(
        colors: [.blue, .purple],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let brandGradientSubtle = LinearGradient(
        colors: [.blue.opacity(0.05), .purple.opacity(0.05)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let heroGradient = LinearGradient(
        colors: [brandBlue, blueDark],
        startPoint: UnitPoint(x: 0.1, y: 0.05),
        endPoint: UnitPoint(x: 0.9, y: 0.95)
    )

    static let logoGradient = LinearGradient(
        colors: [brandBlue, blueDark],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Typography

enum Typography {
    static let largeTitle  = Font.system(size: 34, weight: .bold)
    static let title       = Font.system(size: 28, weight: .bold)
    static let title2      = Font.system(size: 22, weight: .bold)
    static let title3      = Font.system(size: 20, weight: .semibold)
    static let headline    = Font.system(size: 17, weight: .semibold)
    static let body        = Font.system(size: 17, weight: .regular)
    static let callout     = Font.system(size: 16, weight: .regular)
    static let subheadline = Font.system(size: 15, weight: .regular)
    static let footnote    = Font.system(size: 13, weight: .regular)
    static let caption     = Font.system(size: 12, weight: .regular)
    static let caption2    = Font.system(size: 11, weight: .regular)

    enum Size {
        static let xs:    CGFloat = 11
        static let sm:    CGFloat = 13
        static let body:  CGFloat = 16
        static let lg:    CGFloat = 18
        static let xl:    CGFloat = 22
        static let xxl:   CGFloat = 28
        static let title: CGFloat = 34
    }
}

// MARK: - Spacing

enum Spacing {
    static let xxs:     CGFloat = 2
    static let xs:      CGFloat = 4
    static let sm:      CGFloat = 8
    static let md:      CGFloat = 12
    static let lg:      CGFloat = 16
    static let xl:      CGFloat = 20
    static let xxl:     CGFloat = 24
    static let xxxl:    CGFloat = 32
    static let section: CGFloat = 40
}

// MARK: - Radius

enum Radius {
    static let sm:     CGFloat = 8
    static let md:     CGFloat = 12
    static let lg:     CGFloat = 16
    static let xl:     CGFloat = 20
    static let pill:   CGFloat = 25
    static let circle: CGFloat = .infinity
}

// MARK: - Global appearance

enum AppTheme {
    /// Brand-wide UIKit appearance, ported from cardioai-ios (indigo large titles).
    static func apply() {
        UINavigationBar.appearance().largeTitleTextAttributes = [
            .foregroundColor: UIColor.systemIndigo
        ]
    }
}

// MARK: - View styling helpers (cardioai-ios look)

extension View {
    /// White card surface with the brand soft shadow. Apply to already-padded
    /// content (replaces `.ultraThinMaterial` backgrounds).
    func cardSurface(cornerRadius: CGFloat = Radius.lg) -> some View {
        self
            .background(ColorPalette.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(color: Color.gray.opacity(0.12), radius: 6, x: 0, y: 3)
    }

    /// Convenience: pad + white card surface (cardioai-ios `cardStyle`).
    func cardStyle(padding: CGFloat = Spacing.lg, cornerRadius: CGFloat = Radius.lg) -> some View {
        self.padding(padding).cardSurface(cornerRadius: cornerRadius)
    }

    /// Design-accurate card surface matching the CardioAI Onboarding mockup:
    /// white fill, 20-pt radius, layered ink-tinted shadow
    /// (`0 1px 2px / 0 8px 24px rgba(11,18,32,.04–.05)`).
    func designCard(cornerRadius: CGFloat = 20) -> some View {
        self
            .background(ColorPalette.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: ColorPalette.ink.opacity(0.05), radius: 14, x: 0, y: 8)
            .shadow(color: ColorPalette.ink.opacity(0.04), radius: 2,  x: 0, y: 1)
    }

    /// Light app screen background (#F4F6FB) behind a scroll/stack.
    func screenBackground() -> some View {
        self.background(ColorPalette.screenBackground.ignoresSafeArea())
    }
}

// MARK: - Shared design-language components (dashboard look)

/// Rounded-rect tinted icon tile used across cards (soft fill + colored SF Symbol).
/// Matches the dashboard `VitalTile` / `AlertDesignRow` icon treatment.
struct DIconTile: View {
    let icon: String
    let tint: Color
    let color: Color
    var size: CGFloat = 36
    var corner: CGFloat = 10
    var iconSize: CGFloat = 15

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(tint)
                .frame(width: size, height: size)
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(color)
        }
    }
}

/// Large screen headline in the dashboard design language:
/// optional small soft subtitle above a heavy, tight-tracked `ink` title.
/// Use in place of `.navigationTitle(_:).navigationBarTitleDisplayMode(.large)`
/// so every top-level screen reads like the dashboard greeting.
struct DScreenHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ColorPalette.inkSoft)
            }
            Text(title)
                .font(.system(size: 26, weight: .heavy))
                .tracking(-0.6)
                .foregroundStyle(ColorPalette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Small uppercase-free capsule pill (color-tinted) for statuses/badges.
struct DPill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// Full-width empty-state card in the dashboard design language.
struct DEmptyState: View {
    let icon: String
    let tint: Color
    let color: Color
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            DIconTile(icon: icon, tint: tint, color: color, size: 56, corner: 16, iconSize: 24)
            Text(title)
                .font(.system(size: 17, weight: .heavy))
                .tracking(-0.3)
                .foregroundStyle(ColorPalette.ink)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(ColorPalette.inkSoft)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32).padding(.horizontal, 20)
        .designCard(cornerRadius: 20)
    }
}
