import SwiftUI
import AppKit
import AgentNotchCore

// Per-agent glyphs and the icon shells that host them. Split out of
// `NotchView.swift`, which had grown past 4,000 lines: these are pure
// drawing with no dependency on the panel's state machine.

// MARK: - Glyph

struct ClaudeBloomGlyph: View {
    var size: CGFloat
    var color: Color = .orange

    var body: some View {
        Canvas { context, canvasSize in
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let petalLength = canvasSize.height * 0.46
            let petalWidth = canvasSize.width * 0.15
            var petal = Path()
            petal.move(to: .zero)
            petal.addQuadCurve(to: CGPoint(x: 0, y: -petalLength), control: CGPoint(x: petalWidth, y: -petalLength * 0.5))
            petal.addQuadCurve(to: .zero, control: CGPoint(x: -petalWidth, y: -petalLength * 0.5))
            petal.closeSubpath()

            for i in 0..<6 {
                var layer = context
                layer.translateBy(x: center.x, y: center.y)
                layer.rotate(by: .degrees(Double(i) * 60))
                layer.fill(petal, with: .color(color))
            }
            let coreRadius = canvasSize.width * 0.09
            let coreRect = CGRect(x: center.x - coreRadius, y: center.y - coreRadius, width: coreRadius * 2, height: coreRadius * 2)
            context.fill(Path(ellipseIn: coreRect), with: .color(color))
        }
        .frame(width: size, height: size)
    }
}

struct CodexBlobGlyph: View {
    var size: CGFloat
    var color: Color = .white

    var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let lumps: [(CGFloat, CGFloat, CGFloat)] = [
                (0.50, 0.40, 0.34),
                (0.27, 0.56, 0.28),
                (0.73, 0.56, 0.28),
                (0.50, 0.66, 0.30),
                (0.38, 0.32, 0.22),
                (0.63, 0.32, 0.22),
            ]
            for (cx, cy, r) in lumps {
                let rect = CGRect(x: (cx * w) - (r * w / 2), y: (cy * h) - (r * h / 2), width: r * w, height: r * h)
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.92)))
            }
        }
        .frame(width: size, height: size)
    }
}

struct AntigravityGlyph: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [.cyan, .blue, .purple],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: size * 0.68, height: size * 0.68)
                .shadow(color: .cyan.opacity(0.4), radius: 2)
            
            Ellipse()
                .stroke(LinearGradient(
                    colors: [.white, .cyan.opacity(0.8), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                ), lineWidth: size * 0.08)
                .frame(width: size * 1.0, height: size * 0.32)
                .rotationEffect(.degrees(-22))
        }
        .frame(width: size, height: size)
    }
}

struct GeminiGlyph: View {
    var size: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let r = min(w, h) / 2
            
            var path = Path()
            path.move(to: CGPoint(x: w/2, y: h/2 - r))
            path.addQuadCurve(to: CGPoint(x: w/2 + r, y: h/2), control: CGPoint(x: w/2 + r*0.12, y: h/2 - r*0.12))
            path.addQuadCurve(to: CGPoint(x: w/2, y: h/2 + r), control: CGPoint(x: w/2 + r*0.12, y: h/2 + r*0.12))
            path.addQuadCurve(to: CGPoint(x: w/2 - r, y: h/2), control: CGPoint(x: w/2 - r*0.12, y: h/2 + r*0.12))
            path.addQuadCurve(to: CGPoint(x: w/2, y: h/2 - r), control: CGPoint(x: w/2 - r*0.12, y: h/2 - r*0.12))
            path.closeSubpath()
            
            let gradient = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [
                    Color(red: 0.3, green: 0.5, blue: 1.0),
                    Color(red: 0.7, green: 0.3, blue: 0.9),
                    Color(red: 1.0, green: 0.6, blue: 0.3)
                ]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: w, y: h)
            )
            context.fill(path, with: gradient)
        }
        .frame(width: size, height: size)
    }
}

struct CopilotGlyph: View {
    var size: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            
            // Background / head base
            let headRect = CGRect(x: w*0.16, y: h*0.22, width: w*0.68, height: h*0.56)
            let headPath = Path(roundedRect: headRect, cornerRadius: w*0.18)
            
            let headGradient = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [Color(red: 0.5, green: 0.45, blue: 0.95), Color(red: 0.35, green: 0.3, blue: 0.8)]),
                startPoint: CGPoint(x: w*0.16, y: h*0.22),
                endPoint: CGPoint(x: w*0.84, y: h*0.78)
            )
            context.fill(headPath, with: headGradient)
            
            // Visor
            let visorRect = CGRect(x: w*0.26, y: h*0.34, width: w*0.48, height: h*0.24)
            let visorPath = Path(roundedRect: visorRect, cornerRadius: w*0.06)
            context.fill(visorPath, with: .color(.black.opacity(0.85)))
            
            // Ears / headphones
            let earL = CGRect(x: w*0.06, y: h*0.34, width: w*0.1, height: h*0.28)
            let earR = CGRect(x: w*0.84, y: h*0.34, width: w*0.1, height: h*0.28)
            context.fill(Path(roundedRect: earL, cornerRadius: w*0.04), with: .color(Color(red: 0.4, green: 0.35, blue: 0.85)))
            context.fill(Path(roundedRect: earR, cornerRadius: w*0.04), with: .color(Color(red: 0.4, green: 0.35, blue: 0.85)))
            
            // Eyes
            let eyeSize = w*0.08
            let eyeL = CGRect(x: w*0.36, y: h*0.42, width: eyeSize, height: eyeSize)
            let eyeR = CGRect(x: w*0.56, y: h*0.42, width: eyeSize, height: eyeSize)
            context.fill(Path(ellipseIn: eyeL), with: .color(.cyan))
            context.fill(Path(ellipseIn: eyeR), with: .color(.cyan))
        }
        .frame(width: size, height: size)
    }
}

struct CursorGlyph: View {
    var size: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            
            var path = Path()
            path.move(to: CGPoint(x: w*0.18, y: h*0.12))
            path.addLine(to: CGPoint(x: w*0.82, y: h*0.52))
            path.addLine(to: CGPoint(x: w*0.48, y: h*0.56))
            path.addLine(to: CGPoint(x: w*0.62, y: h*0.88))
            path.addLine(to: CGPoint(x: w*0.48, y: h*0.94))
            path.addLine(to: CGPoint(x: w*0.34, y: h*0.62))
            path.addLine(to: CGPoint(x: w*0.12, y: h*0.52))
            path.closeSubpath()
            
            let gradient = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [Color(red: 0.2, green: 0.8, blue: 0.95), Color(red: 0.1, green: 0.4, blue: 0.8)]),
                startPoint: CGPoint(x: w*0.18, y: h*0.12),
                endPoint: CGPoint(x: w*0.62, y: h*0.88)
            )
            context.fill(path, with: gradient)
        }
        .frame(width: size, height: size)
    }
}

struct OpenCodeGlyph: View {
    var size: CGFloat

    var body: some View {
        HStack(spacing: 0.5) {
            Text(">")
                .font(.system(size: size * 0.82, weight: .bold, design: .monospaced))
                .foregroundColor(Color(red: 0.2, green: 0.85, blue: 0.5))
                .shadow(color: Color(red: 0.2, green: 0.85, blue: 0.5).opacity(0.7), radius: 1.5)
            Text("_")
                .font(.system(size: size * 0.82, weight: .bold, design: .monospaced))
                .foregroundColor(Color(red: 0.2, green: 0.85, blue: 0.5))
                .shadow(color: Color(red: 0.2, green: 0.85, blue: 0.5).opacity(0.7), radius: 1.5)
        }
        .frame(width: size, height: size)
    }
}

struct AiderGlyph: View {
    var size: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let center = CGPoint(x: w/2, y: h/2)
            let outerR = w * 0.45
            let innerR = w * 0.20
            
            let outerPath = Path(ellipseIn: CGRect(x: center.x - outerR, y: center.y - outerR, width: outerR * 2, height: outerR * 2))
            context.fill(outerPath, with: .color(.white))
            
            for angle in [45.0, 135.0, 225.0, 315.0] {
                var stripe = Path()
                stripe.move(to: center)
                stripe.addArc(center: center, radius: outerR + 1, startAngle: .degrees(angle - 18), endAngle: .degrees(angle + 18), clockwise: false)
                stripe.closeSubpath()
                context.fill(stripe, with: .color(Color(red: 0.95, green: 0.3, blue: 0.3)))
            }
            
            let innerPath = Path(ellipseIn: CGRect(x: center.x - innerR, y: center.y - innerR, width: innerR * 2, height: innerR * 2))
            context.blendMode = .clear
            context.fill(innerPath, with: .color(.black))
        }
        .frame(width: size, height: size)
    }
}

struct GooseGlyph: View {
    var size: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            
            let headR = w * 0.24
            let headCenter = CGPoint(x: w * 0.45, y: h * 0.38)
            let headPath = Path(ellipseIn: CGRect(x: headCenter.x - headR, y: headCenter.y - headR, width: headR * 2, height: headR * 2))
            context.fill(headPath, with: .color(.white))
            
            var neckPath = Path()
            neckPath.move(to: CGPoint(x: headCenter.x - headR * 0.8, y: headCenter.y + headR * 0.2))
            neckPath.addQuadCurve(to: CGPoint(x: w * 0.2, y: h * 0.95), control: CGPoint(x: w * 0.26, y: h * 0.65))
            neckPath.addLine(to: CGPoint(x: w * 0.62, y: h * 0.95))
            neckPath.addQuadCurve(to: CGPoint(x: headCenter.x + headR * 0.8, y: headCenter.y + headR * 0.2), control: CGPoint(x: w * 0.56, y: h * 0.65))
            neckPath.closeSubpath()
            context.fill(neckPath, with: .color(.white))
            
            let eyeR = w * 0.045
            let eyeRect = CGRect(x: headCenter.x + headR * 0.12, y: headCenter.y - headR * 0.35, width: eyeR * 2, height: eyeR * 2)
            context.fill(Path(ellipseIn: eyeRect), with: .color(.black))
            
            var beakPath = Path()
            beakPath.move(to: CGPoint(x: headCenter.x + headR * 0.65, y: headCenter.y - headR * 0.08))
            beakPath.addLine(to: CGPoint(x: w * 0.92, y: headCenter.y + headR * 0.12))
            beakPath.addLine(to: CGPoint(x: headCenter.x + headR * 0.42, y: headCenter.y + headR * 0.32))
            beakPath.closeSubpath()
            context.fill(beakPath, with: .color(Color(red: 0.98, green: 0.6, blue: 0.15)))
        }
        .frame(width: size, height: size)
    }
}

struct LocalIconView: View {
    let agent: AgentKind
    let size: CGFloat
    let fallback: () -> AnyView

    var body: some View {
        if let image = loadLocalIcon() {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            fallback()
        }
    }

    private func loadLocalIcon() -> NSImage? {
        let homeDir = NSHomeDirectory()
        let path = "\(homeDir)/.agent-notch/icons/\(agent.rawValue).png"
        return NSImage(contentsOfFile: path)
    }
}

@ViewBuilder
func glyphContent(_ agent: AgentKind?, size: CGFloat) -> some View {
    if let agent = agent {
        LocalIconView(agent: agent, size: size) {
            AnyView(fallbackGlyphContent(agent, size: size))
        }
    } else {
        Text("⌁").font(.system(size: size + 1))
    }
}

@ViewBuilder
func fallbackGlyphContent(_ agent: AgentKind, size: CGFloat) -> some View {
    switch agent {
    case .claude:
        ClaudeBloomGlyph(size: size, color: .orange)
    case .codex:
        CodexBlobGlyph(size: size, color: .white)
    case .antigravity:
        AntigravityGlyph(size: size)
    case .gemini:
        GeminiGlyph(size: size)
    case .copilot:
        CopilotGlyph(size: size)
    case .cursor:
        CursorGlyph(size: size)
    case .opencode:
        OpenCodeGlyph(size: size)
    case .aider:
        AiderGlyph(size: size)
    case .goose:
        GooseGlyph(size: size)
    case .mistral, .deepseek, .kimi, .zcode, .trae, .mimocode, .droid, .qoder, .qwen, .codebuddy, .workbuddy, .kiro, .hermes, .amp, .pi, .ohmypi, .gajae:
        // Bespoke fallback: SF Symbol + brand accent color.
        Image(systemName: agent.symbolName)
            .font(.system(size: size * 0.7, weight: .semibold))
            .foregroundStyle(agent.accentColor)
            .frame(width: size, height: size)
    }
}

struct GlyphBox: View {
    let agent: AgentKind?

    var body: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(Color.white.opacity(0.1))
            .frame(width: 22, height: 22)
            .overlay(
                glyphContent(agent, size: 10)
                    .foregroundColor(.white)
            )
    }
}
