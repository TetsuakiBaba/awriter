import SwiftUI
import AppKit
import AVFoundation
import QuartzCore
import UniformTypeIdentifiers

/// 録画直後に出るトリミング画面。プレビューを見ながら開始/終了を決めて mp4 に書き出す。
struct TrimSheet: View {
    let recording: WindowRecorder.Recording

    @Environment(\.dismiss) private var dismiss

    @State private var player = AVPlayer()
    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var playhead: Double = 0
    @State private var isPlaying = false
    @State private var thumbnails: [CGImage] = []
    @State private var timeObserver: Any?

    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var errorMessage: String?

    @AppStorage(ExportResolution.defaultsKey) private var resolution = ExportResolution.original.rawValue

    /// ハンドル同士が潰れないよう最低限これだけは残す。
    private let minimumDuration: Double = 0.2
    /// ハンドルのドラッグはハンドル自身ではなくストリップ全体の座標で測る。
    private static let stripSpace = "trim-strip"

    var body: some View {
        VStack(spacing: 16) {
            preview
            scrubber
            readout
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 720)
        .onAppear(perform: load)
        .onDisappear(perform: teardown)
        .alert("書き出せませんでした", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - プレビュー

    /// シートの内容幅(720 - 左右パディング 20)。
    private static let contentWidth: CGFloat = 680
    private static let maximumPreviewHeight: CGFloat = 400

    /// NSViewRepresentable は固有サイズを持たないので、aspectRatio に任せると潰れる。
    /// 収録サイズの比から表示寸法を自分で決める。
    private var previewSize: CGSize {
        let aspect = recording.size.width / max(1, recording.size.height)
        let height = min(Self.maximumPreviewHeight, Self.contentWidth / max(0.01, aspect))
        return CGSize(width: height * aspect, height: height)
    }

    private var preview: some View {
        PlayerLayerView(player: player)
            .frame(width: previewSize.width, height: previewSize.height)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { _ in
                // forwardPlaybackEndTime に達すると再生は止まるので、ボタンの見た目を戻す
                isPlaying = false
            }
    }

    private var playPauseButton: some View {
        Button {
            togglePlayback()
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .frame(width: 20)
        }
        .help(isPlaying ? "一時停止" : "選択範囲を再生")
    }

    private func togglePlayback() {
        if player.rate != 0 {
            player.pause()
            isPlaying = false
        } else {
            // 範囲外にいるなら開始点から鳴らす
            if playhead < start || playhead >= end - 0.05 { seek(to: start) }
            player.play()
            isPlaying = true
        }
    }

    // MARK: - スクラバ

    private var scrubber: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let handleWidth: CGFloat = 10

            ZStack(alignment: .leading) {
                filmstrip

                // 選択範囲の外は暗く落とす
                Rectangle()
                    .fill(.black.opacity(0.55))
                    .frame(width: x(for: start, in: width))
                Rectangle()
                    .fill(.black.opacity(0.55))
                    .frame(width: width - x(for: end, in: width))
                    .offset(x: x(for: end, in: width))

                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .frame(width: max(handleWidth, x(for: end, in: width) - x(for: start, in: width)))
                    .offset(x: x(for: start, in: width))

                // 再生ヘッド
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 2)
                    .offset(x: x(for: playhead, in: width) - 1)
                    .allowsHitTesting(false)

                handle(at: start, in: width, width: handleWidth, alignedRight: false) { time in
                    start = min(time, end - minimumDuration)
                    seek(to: start)
                }
                handle(at: end, in: width, width: handleWidth, alignedRight: true) { time in
                    end = max(time, start + minimumDuration)
                    applyPlaybackRange()
                    seek(to: end)
                }
            }
            .coordinateSpace(name: Self.stripSpace)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    seek(to: time(for: value.location.x, in: width).clamped(to: start...end))
                }
            )
        }
        .frame(height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var filmstrip: some View {
        HStack(spacing: 0) {
            if thumbnails.isEmpty {
                Rectangle().fill(Color.secondary.opacity(0.15))
            } else {
                ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .clipped()
                }
            }
        }
    }

    private func handle(
        at time: Double,
        in width: CGFloat,
        width handleWidth: CGFloat,
        alignedRight: Bool,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor)
            .overlay(
                Rectangle().fill(.white.opacity(0.85)).frame(width: 2, height: 18)
            )
            .frame(width: handleWidth)
            .offset(x: x(for: time, in: width) - (alignedRight ? handleWidth : 0))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.stripSpace))
                    .onChanged { value in
                        onChange(self.time(for: value.location.x, in: width))
                    }
            )
    }

    // MARK: - 時間表示

    private var readout: some View {
        HStack(spacing: 18) {
            playPauseButton
            label("開始", start)
            label("終了", end)
            label("長さ", end - start)

            Spacer(minLength: 8)

            Button("ここを開始に") {
                start = min(playhead, end - minimumDuration)
            }
            .help("再生ヘッドの位置を開始点にする")

            Button("ここを終了に") {
                end = max(playhead, start + minimumDuration)
                applyPlaybackRange()
            }
            .help("再生ヘッドの位置を終了点にする")
        }
    }

    private func label(_ title: String, _ seconds: Double) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Self.timecode(seconds))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
        }
    }

    // MARK: - フッタ

    private var footer: some View {
        HStack(spacing: 10) {
            if isExporting {
                ProgressView(value: exportProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 180)
                Text("書き出し中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(exportSummary)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Picker("解像度", selection: $resolution) {
                ForEach(ExportResolution.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 130)
            .disabled(isExporting)
            .help("書き出す高さ。元より大きくは書き出さない")

            Button("破棄", role: .destructive) {
                WindowRecorder.shared.discard(recording)
                dismiss()
            }
            .disabled(isExporting)

            Button("書き出し…") { export() }
                .keyboardShortcut(.defaultAction)
                .disabled(isExporting)
        }
    }

    private var selectedResolution: ExportResolution {
        ExportResolution(rawValue: resolution) ?? .original
    }

    /// 実際に書き出される寸法を出す。オリジナルより大きくはならないので、
    /// 1080p を選んでも元が小さければ元の寸法のまま表示される。
    private var exportSummary: String {
        let size = selectedResolution.outputSize(for: recording.size)
        return "\(Int(size.width))×\(Int(size.height))  H.264 / mp4(音声なし)"
    }

    // MARK: - 読み込み

    private func load() {
        end = recording.duration
        let item = AVPlayerItem(url: recording.url)
        player.replaceCurrentItem(with: item)
        applyPlaybackRange()

        // シークしないと最初のフレームが描画されず、プレビューが黒いままになる
        seek(to: 0)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { time in
            playhead = time.seconds
            isPlaying = player.rate != 0
        }

        Task { await loadThumbnails() }
    }

    private func teardown() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func loadThumbnails() async {
        let asset = AVURLAsset(url: recording.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        // 厳密な時刻より速度を優先する(見出し用のサムネイルなので)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)

        let count = 12
        let times = (0..<count).map { index in
            CMTime(seconds: recording.duration * (Double(index) + 0.5) / Double(count), preferredTimescale: 600)
        }

        var images: [CGImage] = []
        for await result in generator.images(for: times) {
            if case .success(_, let image, _) = result { images.append(image) }
        }
        let collected = images
        await MainActor.run { thumbnails = collected }
    }

    // MARK: - 再生範囲の拘束

    private func applyPlaybackRange() {
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 600)
    }

    private func seek(to seconds: Double) {
        playhead = seconds
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
    }

    // MARK: - 書き出し

    private func export() {
        // 再生ヘッドが範囲外にいると書き出し後の確認がしづらいので戻しておく
        if playhead < start || playhead > end { seek(to: start) }
        player.pause()
        isPlaying = false

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = WindowRecorder.suggestedExportName()
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let range = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
        isExporting = true
        exportProgress = 0

        Task {
            do {
                try await VideoTrimmer.export(
                    source: recording.url, range: range, to: destination,
                    resolution: selectedResolution
                ) { value in
                    Task { @MainActor in exportProgress = value }
                }
                WindowRecorder.shared.discard(recording)
                NSWorkspace.shared.activateFileViewerSelecting([destination])
                dismiss()
            } catch {
                isExporting = false
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - 座標と時間の変換

    private func x(for seconds: Double, in width: CGFloat) -> CGFloat {
        guard recording.duration > 0 else { return 0 }
        return CGFloat(seconds / recording.duration) * width
    }

    private func time(for x: CGFloat, in width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return (Double(x / width) * recording.duration).clamped(to: 0...recording.duration)
    }

    private static func timecode(_ seconds: Double) -> String {
        let value = max(0, seconds)
        return String(format: "%02d:%05.2f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60))
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}


/// AVKit の `VideoPlayer` は使わない。Swift の自動リンクでは AVKit 本体がリンクされず、
/// `_AVKit_SwiftUI` だけが読み込まれて生成時に metadata 解決に失敗しクラッシュする。
/// トリム用のスクラバは自前で持っているので、AVKit の再生コントロールも不要。
private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerNSView, context: Context) {
        if nsView.playerLayer.player !== player { nsView.playerLayer.player = player }
    }
}

final class PlayerNSView: NSView {
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
}
