import AppKit
import SwiftUI

enum TBDesignTokens {
    enum ColorToken {
        static let glassOverlay = Color(NSColor(name: NSColor.Name("TBGlassOverlay")) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.black.withAlphaComponent(0.26)
                : NSColor.white.withAlphaComponent(0.46)
        })

        static let glassFill = Color(NSColor(name: NSColor.Name("TBGlassFill")) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.08)
                : NSColor.white.withAlphaComponent(0.70)
        })

        static let glassFillHover = Color(NSColor(name: NSColor.Name("TBGlassFillHover")) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.14)
                : NSColor.white.withAlphaComponent(0.88)
        })

        static let hairline = Color(NSColor(name: NSColor.Name("TBGlassHairline")) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.16)
                : NSColor.black.withAlphaComponent(0.10)
        })

        static let hairlineHover = Color(NSColor(name: NSColor.Name("TBGlassHairlineHover")) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.25)
                : NSColor.black.withAlphaComponent(0.18)
        })

        static let subduedText = Color.secondary
        static let timerTrack = Color.primary.opacity(0.12)
        static let timerTrackShadow = Color.primary.opacity(0.04)
        static let accent = Color.accentColor
    }

    enum Radius {
        static let popover: CGFloat = 18
        static let card: CGFloat = 16
        static let button: CGFloat = 10
        static let pill: CGFloat = 999
    }

    enum Spacing {
        static let xsmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
    }

    enum Animation {
        static let quick = SwiftUI.Animation.easeOut(duration: 0.14)
        static let smooth = SwiftUI.Animation.easeInOut(duration: 0.22)
        static let spring = SwiftUI.Animation.spring(response: 0.28, dampingFraction: 0.78)
    }
}

struct TBVisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    init(material: NSVisualEffectView.Material = .popover,
         blendingMode: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.material = material
        self.blendingMode = blendingMode
    }

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context _: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}

private struct TBGlassPopoverBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(TBDesignTokens.ColorToken.glassOverlay)
            .background(TBVisualEffectBackground(material: .popover, blendingMode: .behindWindow))
            .clipShape(RoundedRectangle(cornerRadius: TBDesignTokens.Radius.popover, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: TBDesignTokens.Radius.popover, style: .continuous)
                    .strokeBorder(TBDesignTokens.ColorToken.hairline, lineWidth: 0.75)
                    .allowsHitTesting(false)
            )
            .shadow(color: Color.black.opacity(0.10), radius: 10, x: 0, y: 6)
    }
}

private struct TBTimerFaceSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                Circle()
                    .fill(TBDesignTokens.ColorToken.glassFill)
                    .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)
            )
            .overlay(
                Circle()
                    .strokeBorder(TBDesignTokens.ColorToken.hairline, lineWidth: 0.75)
            )
    }
}

private struct TBGlassCapsuleModifier: ViewModifier {
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let isProminent: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                Capsule()
                    .fill(backgroundColor)
            )
            .overlay(
                Capsule()
                    .strokeBorder(isHovered ? TBDesignTokens.ColorToken.hairlineHover : TBDesignTokens.ColorToken.hairline,
                                  lineWidth: 0.75)
                    .allowsHitTesting(false)
            )
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(TBDesignTokens.Animation.quick, value: isHovered)
    }

    private var backgroundColor: Color {
        if isProminent {
            return TBDesignTokens.ColorToken.accent.opacity(isHovered ? 0.98 : 0.90)
        }
        return isHovered ? TBDesignTokens.ColorToken.glassFillHover : TBDesignTokens.ColorToken.glassFill
    }
}

private struct TBGlassCapsuleButtonStyle: ButtonStyle {
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let isProminent: Bool

    func makeBody(configuration: Configuration) -> some View {
        TBGlassCapsuleButtonLabel(configuration: configuration,
                                  horizontalPadding: horizontalPadding,
                                  verticalPadding: verticalPadding,
                                  isProminent: isProminent)
    }
}

private struct TBGlassCapsuleButtonLabel: View {
    let configuration: ButtonStyle.Configuration
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let isProminent: Bool
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                Capsule()
                    .fill(backgroundColor)
            )
            .overlay(
                Capsule()
                    .strokeBorder(isHovered ? TBDesignTokens.ColorToken.hairlineHover : TBDesignTokens.ColorToken.hairline,
                                  lineWidth: 0.75)
                    .allowsHitTesting(false)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .contentShape(Capsule())
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(TBDesignTokens.Animation.quick, value: isHovered)
            .animation(TBDesignTokens.Animation.quick, value: configuration.isPressed)
    }

    private var backgroundColor: Color {
        if isProminent {
            return TBDesignTokens.ColorToken.accent.opacity(isHovered ? 0.98 : 0.90)
        }
        return isHovered ? TBDesignTokens.ColorToken.glassFillHover : TBDesignTokens.ColorToken.glassFill
    }
}

enum TBPopoverButtonRole {
    case primary
    case secondary
    case destructiveQuiet
}

private struct TBPopoverButtonStyle: ButtonStyle {
    let role: TBPopoverButtonRole
    let minWidth: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        TBPopoverButtonLabel(configuration: configuration,
                             role: role,
                             minWidth: minWidth)
    }
}

private struct TBPopoverButtonLabel: View {
    let configuration: ButtonStyle.Configuration
    let role: TBPopoverButtonRole
    let minWidth: CGFloat
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TBDesignTokens.Radius.button, style: .continuous)

        configuration.label
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundColor(foregroundColor)
            .frame(minWidth: minWidth, minHeight: 32)
            .padding(.horizontal, 10)
            .background(
                shape.fill(backgroundColor)
            )
            .overlay(
                shape.strokeBorder(isHovered ? TBDesignTokens.ColorToken.hairlineHover : TBDesignTokens.ColorToken.hairline,
                                   lineWidth: 0.75)
                    .allowsHitTesting(false)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .contentShape(shape)
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(TBDesignTokens.Animation.quick, value: isHovered)
            .animation(TBDesignTokens.Animation.quick, value: configuration.isPressed)
    }

    private var backgroundColor: Color {
        switch role {
        case .primary:
            return TBDesignTokens.ColorToken.accent.opacity(isHovered ? 1.0 : 0.92)
        case .secondary:
            return isHovered ? TBDesignTokens.ColorToken.glassFillHover : TBDesignTokens.ColorToken.glassFill
        case .destructiveQuiet:
            return isHovered ? Color.red.opacity(0.16) : TBDesignTokens.ColorToken.glassFill
        }
    }

    private var foregroundColor: Color {
        switch role {
        case .primary:
            return .white
        case .secondary:
            return .primary
        case .destructiveQuiet:
            return isHovered ? Color.red : .primary
        }
    }
}

private struct TBIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TBIconButtonLabel(configuration: configuration)
    }
}

private struct TBIconButtonLabel: View {
    let configuration: ButtonStyle.Configuration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(isHovered ? .primary : TBDesignTokens.ColorToken.subduedText)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? TBDesignTokens.ColorToken.glassFillHover : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isHovered ? TBDesignTokens.ColorToken.hairline : Color.clear, lineWidth: 0.5)
                    .allowsHitTesting(false)
            )
            .opacity(configuration.isPressed ? 0.78 : 1)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(TBDesignTokens.Animation.quick, value: isHovered)
            .animation(TBDesignTokens.Animation.quick, value: configuration.isPressed)
    }
}

extension View {
    func tbGlassPopoverBackground() -> some View {
        modifier(TBGlassPopoverBackground())
    }

    func tbTimerFaceSurface() -> some View {
        modifier(TBTimerFaceSurface())
    }

    func tbGlassCapsule(horizontalPadding: CGFloat = 10,
                        verticalPadding: CGFloat = 5,
                        isProminent: Bool = false) -> some View {
        modifier(TBGlassCapsuleModifier(horizontalPadding: horizontalPadding,
                                        verticalPadding: verticalPadding,
                                        isProminent: isProminent))
    }

    func tbGlassCapsuleButton(horizontalPadding: CGFloat = 10,
                              verticalPadding: CGFloat = 5,
                              isProminent: Bool = false) -> some View {
        buttonStyle(TBGlassCapsuleButtonStyle(horizontalPadding: horizontalPadding,
                                              verticalPadding: verticalPadding,
                                              isProminent: isProminent))
    }

    func tbPopoverButton(role: TBPopoverButtonRole = .secondary,
                         minWidth: CGFloat) -> some View {
        buttonStyle(TBPopoverButtonStyle(role: role, minWidth: minWidth))
    }

    func tbIconButton() -> some View {
        buttonStyle(TBIconButtonStyle())
    }
}
