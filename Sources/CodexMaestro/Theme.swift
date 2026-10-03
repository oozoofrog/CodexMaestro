import SwiftUI
import AppKit
import MaestroCore

enum Palette {
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            color(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }
    static let canvas = adaptive(0xf7f8fa, 0x242629)
    static let background = canvas
    static let panel = adaptive(0xffffff, 0x202124)
    static let sidebar = adaptive(0xeef0f3, 0x292b2f)
    static let card = adaptive(0xf2f4f7, 0x2c2f34)
    static let border = adaptive(0xd9dde3, 0x41464e)
    static let branch = adaptive(0xb7bec8, 0x636b76)
    static let grid = adaptive(0xdde2e9, 0x3a4048)
    static let selection = adaptive(0xe2edfb, 0x31465e)
    static let blue = adaptive(0x0869d1, 0x83baff)
    static let accent = blue
    static let mint = adaptive(0x277346, 0x8aceab)
    static let text = adaptive(0x24262a, 0xeceef1)
    static let muted = adaptive(0x666d76, 0xa9b0b8)
    static let purple = adaptive(0x8556bd, 0xc5a6ed)
    static let amber = adaptive(0x9b6517, 0xe6b96e)
    static let red = adaptive(0xbe3947, 0xf69ca7)
    static func project(_ index: Int) -> Color { blue }
    static func status(_ status: SessionStatus) -> Color {
        switch status { case .running: mint; case .waiting: amber; case .idle: blue; case .unknown: muted; case .error: red }
    }
    static func link(_ kind: LinkKind) -> Color { switch kind { case .context: blue; case .dependency: amber; case .review: purple } }
}
struct StatusPill: View {
    let status: SessionStatus
    var body: some View {
        HStack(spacing: 5) { Circle().fill(Palette.status(status)).frame(width: 5, height: 5); Text(status.label).font(.system(size: 10, weight: .medium)) }
            .foregroundStyle(Palette.status(status)).padding(.horizontal, 7).padding(.vertical, 4)
            .background(Palette.status(status).opacity(0.09), in: Capsule())
    }
}
struct SessionStatePill: View {
    let session: Session
    var body: some View {
        if session.isLive {
            StatusPill(status: session.status).help("실시간 세션 상태")
        } else {
            Label("저장 기록", systemImage: "clock").font(.system(size: 10)).foregroundStyle(Palette.muted)
                .help("실시간 상태를 확인하지 않은 저장된 세션입니다.")
        }
    }
}
struct Eyebrow: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 10, weight: .semibold, design: .default)).foregroundStyle(Palette.muted) }
}
struct ToolButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 29, height: 29).foregroundStyle(active ? Palette.accent : Palette.muted).background(active ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 6)) }
            .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}
struct EmptyPanel: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 13) { Image(systemName: symbol).font(.system(size: 32, weight: .ultraLight)).foregroundStyle(Palette.mint); Text(title).font(.system(size: 16, weight: .semibold)); Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center).lineSpacing(4) }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
