import SwiftUI
import AppKit

/// 再生中に常に最前面へ浮かべる状態表示。
/// 書類ウィンドウが前面でも見えるようフローティングにし、
/// キーフォーカスを奪わない(奪うと IME の変換が壊れる)。
@MainActor
enum PlaybackHUD {
    static let visibilityDefaultsKey = "showsPlaybackHUD"

    private static var panel: NSPanel?

    private static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: visibilityDefaultsKey) as? Bool ?? true
    }

    static func show() {
        guard isEnabled else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
    }

    static func hide() {
        panel?.orderOut(nil)
    }

    private static func makePanel() -> NSPanel {
        let size = NSSize(width: 264, height: 78)
        let panel = NonActivatingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let hosting = NSHostingView(rootView: PlaybackHUDView())
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting

        // 既定は主ディスプレイの右上。以後はユーザーが動かした位置を復元する。
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.maxX - size.width - 24,
                y: frame.maxY - size.height - 24
            ))
        }
        panel.setFrameAutosaveName("PlaybackHUD")
        return panel
    }
}

/// キーウィンドウにならないパネル。停止ボタンを押しても書類側のフォーカスが外れない。
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct PlaybackHUDView: View {
    @ObservedObject private var player = DemoPlayer.shared

    var body: some View {
        HStack(spacing: 12) {
            leading

            VStack(alignment: .leading, spacing: 3) {
                Text(player.phase.headline)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                Text("ESC で停止")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if let progress = player.phase.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.red)
                        .frame(height: 2)
                }
            }

            Spacer(minLength: 0)

            Button {
                DemoPlayer.shared.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .background(Color.red.opacity(0.85), in: Circle())
            .foregroundStyle(.white)
            .help("再生を停止")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 264, height: 78)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.red.opacity(0.55), lineWidth: 2)
        }
    }

    @ViewBuilder
    private var leading: some View {
        if case .countdown(let remaining) = player.phase {
            Text("\(remaining)")
                .font(.system(size: 30, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.red)
                .frame(width: 34)
        } else {
            PulsingDot()
                .frame(width: 34)
        }
    }
}

/// 「収録中」を思わせる点滅インジケータ。
struct PulsingDot: View {
    var diameter: CGFloat = 11
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: diameter, height: diameter)
            .opacity(dimmed ? 0.25 : 1)
            .animation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true), value: dimmed)
            .onAppear { dimmed = true }
    }
}
