import SwiftUI

/// What runs in a pane, as a small coloured icon (#337): an SF Symbol in the
/// program's colour, or for brands without a fitting symbol (Claude Code,
/// Codex ...) a rounded tile with one or two letters. A program missing
/// from the table gets a dashed question mark, a pane nothing is known
/// about yet the terminal in grey. The name is the tooltip.
struct ProgramIcon: View {
    let program: ProgramItem?
    var size: CGFloat = 14

    var body: some View {
        icon
            .frame(width: size, height: size)
            .help(label)
            .accessibilityLabel(label)
    }

    private var label: String {
        program?.name ?? String(localized: "Shell")
    }

    @ViewBuilder
    private var icon: some View {
        if let program {
            if !program.known {
                symbol("questionmark.app.dashed", .secondary)
            } else if let name = Self.symbols[program.id] {
                symbol(name, Color(programHex: program.color))
            } else {
                tile(Self.tiles[program.id] ?? String(program.name.prefix(2)), Color(programHex: program.color))
            }
        } else {
            symbol("apple.terminal", .secondary)
        }
    }

    private func symbol(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            .foregroundStyle(color)
    }

    private func tile(_ letters: String, _ color: Color) -> some View {
        RoundedRectangle(cornerRadius: size * 0.25)
            .fill(color)
            .overlay {
                Text(letters)
                    .font(.system(size: size * (letters.count > 1 ? 0.5 : 0.62), weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
    }

    /// Program id (`herdr_core::programs`) → SF Symbol.
    private static let symbols: [String: String] = {
        var map: [String: String] = [:]
        func set(_ symbol: String, _ ids: String...) { for id in ids { map[id] = symbol } }
        set("pencil.line", "vim", "nvim", "emacs", "nano", "helix", "micro")
        set("doc.text", "less")
        set("book", "man")
        set("cpu", "htop")
        set("network", "ssh")
        set("rectangle.split.2x1", "tmux")
        set("shippingbox", "docker", "npm", "pnpm", "yarn", "uv", "composer")
        set("steeringwheel", "kubectl")
        set("brain", "ollama")
        set("arrow.triangle.branch", "git", "lazygit")
        set("arrow.triangle.pull", "gh")
        set("hammer", "make", "gradle", "xcodebuild")
        set("gearshape.2", "cargo")
        set("swift", "swift")
        set("bolt.fill", "vite")
        set("sparkles", "astro")
        set("cube", "webpack")
        set("arrow.clockwise", "nodemon")
        set("checkmark.seal", "eslint")
        set("testtube.2", "jest", "vitest", "playwright", "pytest")
        set("cylinder", "psql", "mysql", "sqlite", "redis")
        set("chevron.left.forwardslash.chevron.right", "node", "python", "ruby", "bun", "deno", "php")
        set("apple.terminal", "zsh", "bash", "fish", "sh", "nu", "pwsh")
        return map
    }()

    /// Letters for brands without a symbol; others take the first two
    /// letters of their name.
    private static let tiles: [String: String] = [
        "claude": "Cl", "codex": "Cx", "opencode": "oc", "gemini": "Ge", "amp": "A",
        "cursor": "Cu", "droid": "Dr", "pi": "π", "qwen": "Qw", "copilot": "Co",
        "grok": "Gk", "kimi": "Ki", "aider": "Ai", "go": "Go", "tsc": "TS",
        "next": "N", "nuxt": "Nx", "tauri": "Ta", "artisan": "L", "wp": "W",
    ]
}

extension Color {
    /// `#RRGGBB` from the core's program table; grey if it does not parse.
    init(programHex hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self = .gray
            return
        }
        self = RGB(hex: value).color
    }
}
