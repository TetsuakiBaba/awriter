import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 録画の設定。teaser.mp4 のように背景の上に窓を浮かせるかどうかをここで決める。
struct RecordingSettingsPanel: View {
    @AppStorage(WindowRecorder.showsCursorDefaultsKey) private var showsCursor = false
    @AppStorage(BackdropSettings.enabledKey) private var backdropEnabled = false
    @AppStorage(BackdropSettings.fillKey) private var fill = BackdropFill.image.rawValue
    @AppStorage(BackdropSettings.imagePathKey) private var backdropImagePath = ""
    @AppStorage(BackdropSettings.colorKey) private var colorHex = BackdropSettings.defaultColorHex
    @AppStorage(BackdropSettings.marginKey) private var margin = BackdropSettings.defaultMargin
    @AppStorage(BackdropSettings.shadowKey) private var showsShadow = true
    @AppStorage(BackdropSettings.aspectKey) private var aspect = BackdropAspect.sixteenNine.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("マウスカーソルを含める", isOn: $showsCursor)
                .help("タイピングのデモではふつうオフのままでよい")

            Divider()

            Toggle("背景を付ける", isOn: $backdropEnabled)
                .help("書類ウィンドウを背景の上に余白付きで浮かせて録画する")

            Group {
                previewRow
                fillRow
                marginRow
                aspectRow
                Toggle("影を落とす", isOn: $showsShadow)
            }
            .disabled(!backdropEnabled)
            .opacity(backdropEnabled ? 1 : 0.4)

            Text("ウィンドウは等倍のまま重ねるので、背景を付けても文字は滲まない。書き出しサイズはウィンドウより大きくなる。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 340)
    }

    // MARK: - 現在の設定

    private var settings: BackdropSettings {
        BackdropSettings(
            isEnabled: backdropEnabled,
            fill: BackdropFill(rawValue: fill) ?? .image,
            imagePath: backdropImagePath.isEmpty ? nil : backdropImagePath,
            colorHex: colorHex,
            marginRatio: margin,
            showsShadow: showsShadow,
            aspect: BackdropAspect(rawValue: aspect) ?? .sixteenNine
        )
    }

    /// 録画対象になる書類ウィンドウの実ピクセルサイズ。開いていなければ既定サイズで代用する。
    private var windowPixelSize: CGSize {
        guard let window = DemoPlayer.documentWindow() else {
            return CGSize(width: 860 * 2, height: 680 * 2)
        }
        let scale = window.backingScaleFactor
        return CGSize(width: window.frame.width * scale, height: window.frame.height * scale)
    }

    private var geometry: BackdropGeometry? {
        BackdropGeometry.make(windowPixelSize: windowPixelSize, settings: settings)
    }

    // MARK: - プレビュー(実際の書き出しと同じ縦横比・同じ余白で出す)

    private var previewRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let geometry {
                GeometryReader { proxy in
                    let scale = proxy.size.width / geometry.canvasSize.width
                    ZStack {
                        background
                        RoundedRectangle(cornerRadius: max(2, geometry.cornerRadius * scale))
                            .fill(Color(nsColor: .paper))
                            .frame(
                                width: geometry.windowRect.width * scale,
                                height: geometry.windowRect.height * scale
                            )
                            .shadow(
                                color: .black.opacity(showsShadow ? 0.45 : 0),
                                radius: geometry.canvasSize.height * 0.018 * scale,
                                y: geometry.canvasSize.height * 0.012 * scale
                            )
                    }
                }
                .aspectRatio(geometry.canvasSize.width / geometry.canvasSize.height, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 5))

                Text("書き出し \(Int(geometry.canvasSize.width))×\(Int(geometry.canvasSize.height))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var background: some View {
        switch settings.fill {
        case .color:
            Color(nsColor: NSColor(hex: colorHex) ?? .black)
        case .image:
            if let image = previewImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                // 画像未選択のときの代用(合成側のグラデーションと同じ色)
                LinearGradient(
                    colors: [Color(red: 0.16, green: 0.25, blue: 0.28),
                             Color(red: 0.05, green: 0.09, blue: 0.11)],
                    startPoint: .top, endPoint: .bottom
                )
            }
        }
    }

    // MARK: - 背景の種類

    private var fillRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("背景", selection: $fill) {
                ForEach(BackdropFill.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch settings.fill {
            case .color:
                ColorPicker("背景色", selection: Binding(
                    get: { Color(nsColor: NSColor(hex: colorHex) ?? .black) },
                    set: { colorHex = NSColor($0).hexString }
                ))
            case .image:
                HStack(spacing: 8) {
                    Button("画像を選択…") { chooseImage() }
                    if !backdropImagePath.isEmpty {
                        Button("消す") { backdropImagePath = "" }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var previewImage: NSImage? {
        guard !backdropImagePath.isEmpty else { return nil }
        return NSImage(contentsOfFile: backdropImagePath)
    }

    /// 選んだ画像はコンテナ内へコピーする。次回起動でもブックマークなしで読めるようにするため。
    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let source = panel.url else { return }

        do {
            let store = try BackdropSettings.imageStoreURL()
            let name = "backdrop-\(UUID().uuidString.prefix(8))." + (source.pathExtension.isEmpty ? "png" : source.pathExtension)
            let destination = store.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source, to: destination)
            // 前の画像は残しても意味がないので片付ける
            let previous = backdropImagePath
            backdropImagePath = destination.path
            if !previous.isEmpty { try? FileManager.default.removeItem(atPath: previous) }
        } catch {
            let alert = NSAlert()
            alert.messageText = "背景画像を読み込めませんでした"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: - 余白と比率

    private var marginRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("余白")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((margin * 100).rounded())) %")
                    .font(.caption)
                    .monospacedDigit()
            }
            Slider(value: $margin, in: 0...0.25)
        }
    }

    private var aspectRow: some View {
        Picker("縦横比", selection: $aspect) {
            ForEach(BackdropAspect.allCases) { option in
                Text(option.label).tag(option.rawValue)
            }
        }
        .pickerStyle(.menu)
    }
}
