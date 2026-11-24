import SwiftUI

/// Design tokens and small shared pieces. Rules from ui-tips-from-videos.md:
/// translucent borders, concentric corners, lighter surfaces for higher layers in dark mode,
/// tabular digits for changing numbers, presses to 0.97, short ease-out motion, Reduce Motion respected.
enum Theme {
    static let cardRadius: CGFloat = 20
    static let cardPadding: CGFloat = 8
    /// Concentric with the card: outer radius minus padding.
    static let innerRadius: CGFloat = cardRadius - cardPadding

    static let page = Color(light: Color(white: 0.96), dark: Color(red: 0.055, green: 0.055, blue: 0.067))   // #0e0e11
    static let card = Color(light: .white, dark: Color(red: 0.090, green: 0.090, blue: 0.106))                // #17171b
    static let raised = Color(light: .white, dark: Color(red: 0.133, green: 0.133, blue: 0.157))              // #222228
    static let border = Color.primary.opacity(0.12)

    static let live = Color(red: 0.20, green: 0.74, blue: 0.42)
    static let minimized = Color(red: 0.95, green: 0.62, blue: 0.16)
    static let sharing = Color(red: 0.28, green: 0.52, blue: 0.98)
    static let offline = Color.secondary

    /// Strong ease-out, under 300 ms.
    static let easeOut = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.22)
}

extension Color {
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
    }
}

/// Presses down to 0.97 with a quick ease-out.
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// A filled capsule button for primary actions.
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(.white)
            .background(tint.opacity(isEnabled ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Shakes horizontally each time `trigger` changes. Used for invalid codes and tokens.
struct Shake: ViewModifier {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: CGFloat(0), trigger: trigger) { view, x in
            view.offset(x: reduceMotion ? 0 : x)
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(-10, duration: 0.06)
                LinearKeyframe(10, duration: 0.06)
                LinearKeyframe(-6, duration: 0.06)
                LinearKeyframe(6, duration: 0.06)
                LinearKeyframe(-3, duration: 0.06)
                LinearKeyframe(0, duration: 0.06)
            }
        }
    }
}

extension View {
    func shake(_ trigger: Int) -> some View { modifier(Shake(trigger: trigger)) }

    /// A card surface: translucent border and a soft layered shadow.
    func cardSurface(radius: CGFloat = Theme.cardRadius, fill: Color = Theme.card) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.04), radius: 4, y: 4)
            .shadow(color: .black.opacity(0.04), radius: 16, y: 16)
    }
}

/// Top banner for warnings, errors and success.
struct BannerView: View {
    let banner: Banner
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.body.weight(.semibold))
                Text(banner.text).font(.subheadline.weight(.medium)).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if banner.sticky { Image(systemName: "xmark").font(.footnote.weight(.semibold)).opacity(0.7) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
        }
        .buttonStyle(PressableStyle())
        .padding(.horizontal, 16)
        .accessibilityHint(banner.sticky ? "Dismisses the message" : "")
    }

    private var icon: String {
        switch banner.style {
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch banner.style {
        case .warning: return Color(red: 0.80, green: 0.48, blue: 0.05)
        case .error: return Color(red: 0.82, green: 0.22, blue: 0.24)
        case .success: return Color(red: 0.13, green: 0.60, blue: 0.34)
        }
    }
}

/// Formats remaining time as m:ss.
func countdownText(until end: Date, now: Date) -> String {
    let s = max(0, Int(end.timeIntervalSince(now).rounded(.up)))
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// "just now", "2m ago", "1h ago".
func ageText(since date: Date, now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(date)))
    if s < 60 { return "just now" }
    if s < 3600 { return "\(s / 60)m ago" }
    return "\(s / 3600)h ago"
}
