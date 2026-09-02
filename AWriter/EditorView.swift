import SwiftUI
import AppKit

struct EditorView: View {
    @AppStorage("editorText") private var text: String = ""
    @AppStorage(EditorWindowTitle.defaultsKey) private var windowTitle: String = ""

    @AppStorage("fontID") private var fontID: String = FontOption.defaultID
    @AppStorage("fontSize") private var fontSize: Double = 16
    @AppStorage("textColorHex") private var textColorHex: String = TextInk.automaticID

    @AppStorage(KeystrokeSettings.positionKey) private var keycastPosition = KeystrokePosition.bottom.rawValue

    @Environment(\.openWindow) private var openWindow
    @State private var showsTypographyPanel = false
    @State private var hasOpenedScriptEditor = false

    private var keycastPlacement: KeystrokePosition {
        KeystrokePosition(rawValue: keycastPosition) ?? .bottom
    }

    var body: some View {
        EditorTextView(
            text: $text,
            font: FontOption.option(for: fontID).font(ofSize: fontSize),
            textColor: TextInk.nsColor(for: textColorHex)
        )
        .overlay(alignment: keycastPlacement.alignment) {
            if keycastPlacement.followsCaret {
                CaretKeystrokeOverlay()
            } else {
                KeystrokeOverlayView()
                    .padding(.horizontal, 24)
                    .padding(.vertical, 28)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text("\(text.count) 文字")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(12)
        }
        .background(EditorWindowTitle(title: windowTitle))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsTypographyPanel.toggle()
                } label: {
                    Label("文字組み", systemImage: "textformat")
                }
                .help("フォント・サイズ・文字色")
                .popover(isPresented: $showsTypographyPanel, arrowEdge: .bottom) {
                    TypographyPanel(
                        fontID: $fontID,
                        fontSize: $fontSize,
                        colorHex: $textColorHex
                    )
                }
            }
        }
        .onAppear {
            guard !hasOpenedScriptEditor else { return }
            hasOpenedScriptEditor = true
            openWindow(id: AWriterApp.scriptWindowID)
        }
    }
}

/// 書類ではないのでタイトルは常に自前で決める。既定は空(タイトルバーに何も出さない)。
struct EditorWindowTitle: NSViewRepresentable {
    static let defaultsKey = "editorWindowTitle"

    let title: String

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let title = title
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            if window.title != title { window.title = title }
            if !window.subtitle.isEmpty { window.subtitle = "" }
            if window.representedURL != nil { window.representedURL = nil }
        }
    }
}
