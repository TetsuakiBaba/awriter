import AppKit
import AVFoundation
import ScreenCaptureKit

/// 書類ウィンドウ(AWTextView を含む窓)だけを ScreenCaptureKit で切り出し、
/// H.264 / mp4(音声なし)として書き出す録画エンジン。
///
/// 既定では、書類窓の範囲の画面を「書類窓 + 入力メソッドの窓」だけに絞って撮る
/// (`SCContentFilter(display:excludingApplications:exceptingWindows:)`)。変換候補の窓や
/// IME が出す小窓は IME のプロセスが持つ別の窓なので、窓単体の撮り方では映らないため。
/// AWriter 自身の窓は書類窓以外を除くので、手前に台本エディタや PlaybackHUD が重なっていても
/// 映らない。キーキャスト表示は EditorView の overlay = 書類窓の中身なので、そのまま映像に入る。
/// 「入力メソッドの窓を含める」を切ると、従来どおり `SCContentFilter(desktopIndependentWindow:)` で
/// 書類窓だけを撮る。
@MainActor
final class WindowRecorder: NSObject, ObservableObject {
    static let shared = WindowRecorder()

    /// マウスカーソルを録画に含めるか。デモメニューのトグルから操作する。
    static let showsCursorDefaultsKey = "recorderShowsCursor"

    /// 入力メソッド(IME)の窓を録画に含めるか。録画設定のトグルから操作する。既定はオン。
    static let includesInputMethodWindowsDefaultsKey = "recorderIncludesInputMethodWindows"

    enum Phase: Equatable {
        case idle
        case preparing
        case recording(startedAt: Date)
        case finishing

        var isActive: Bool { self != .idle }
    }

    /// 録り終わった素材。トリムシートの提示トリガを兼ねる。
    struct Recording: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let size: CGSize
        let duration: Double
    }

    enum RecorderError: LocalizedError {
        case noDocumentWindow
        case windowNotShareable
        case notAuthorized
        case noFrames

        var errorDescription: String? {
            switch self {
            case .noDocumentWindow:
                return "書類ウィンドウがありません"
            case .windowNotShareable:
                return "書類ウィンドウを録画対象として取得できませんでした"
            case .notAuthorized:
                return "画面収録が許可されていません"
            case .noFrames:
                return "フレームを取得できませんでした"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published var finished: Recording?

    private var stream: SCStream?
    private var sink: FrameSink?
    private var outputURL: URL?
    private var outputSize: CGSize = .zero
    private weak var lockedWindow: NSWindow?
    private var restoresResizable = false

    private override init() { super.init() }

    var showsCursor: Bool {
        UserDefaults.standard.bool(forKey: Self.showsCursorDefaultsKey)
    }

    var includesInputMethodWindows: Bool {
        UserDefaults.standard.object(forKey: Self.includesInputMethodWindowsDefaultsKey) as? Bool ?? true
    }

    // MARK: - 開始

    /// 書類ウィンドウの録画を開始する。呼び出し側は再生よりも先にこれを await すること
    /// (startCapture の完了までに 100〜300ms かかるため)。
    func start() async throws {
        guard phase == .idle else { return }
        guard let window = DemoPlayer.documentWindow() else { throw RecorderError.noDocumentWindow }

        phase = .preparing
        do {
            try await beginCapture(of: window)
        } catch {
            phase = .idle
            unlockWindowSize()
            throw error
        }
    }

    private func beginCapture(of window: NSWindow) async throws {
        window.makeKeyAndOrderFront(nil)

        let content: SCShareableContent
        do {
            // 未許可なら初回はここでシステムの許可ダイアログが出て、以降は -3801 を投げる。
            // 画面に出ていない窓しか持たないアプリも除外の一覧に入れたいので、画面外の窓も含めて取る。
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw Self.isAuthorizationFailure(error) ? RecorderError.notAuthorized : error
        }

        let targetID = CGWindowID(window.windowNumber)
        guard let scWindow = content.windows.first(where: { $0.windowID == targetID }) else {
            throw RecorderError.windowNotShareable
        }

        let scale = window.backingScaleFactor
        let width = Self.even(scWindow.frame.width * scale)
        let height = Self.even(scWindow.frame.height * scale)
        guard width > 0, height > 0 else { throw RecorderError.windowNotShareable }

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 6
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.capturesAudio = false
        configuration.showsCursor = showsCursor
        configuration.scalesToFit = true
        // SCStreamConfiguration.backgroundColor は使わない。macOS 26.5 では clear 以外の色を
        // 入れると -[SCStream serializeStreamProperties] が CGColorSpaceGetModel(NULL) で
        // クラッシュする(色空間の指定では回避できない)。角丸の透過は FrameSink 側で潰す。

        // 背景ありなら出力はキャンバス寸法、なしなら窓の寸法そのまま。
        let settings = BackdropSettings.stored
        let compositor = settings.isEnabled
            ? BackdropCompositor(windowPixelSize: CGSize(width: width, height: height), settings: settings)
            : nil
        let outputSize = compositor?.canvasSize ?? CGSize(width: width, height: height)

        let url = try Self.makeOutputURL()
        let sink = try FrameSink(
            url: url,
            width: Int(outputSize.width),
            height: Int(outputSize.height),
            backdrop: Self.backdrop(),
            compositor: compositor
        )

        let windowOnlyFilter = SCContentFilter(desktopIndependentWindow: scWindow)
        var filter = windowOnlyFilter
        var cornerMask: CornerMask?
        if includesInputMethodWindows,
           let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: scWindow.frame.midX, y: scWindow.frame.midY)) }) {
            // 窓の角丸の形は、窓だけを撮った 1 枚から取る。画面ごと撮ると角の外に何が写るか
            // (透過か黒か)が OS に左右されるので、毎フレームこの形で角を抜き直す。
            let maskSample = try? await SCScreenshotManager.captureSampleBuffer(
                contentFilter: windowOnlyFilter, configuration: configuration
            )
            if let maskBuffer = maskSample?.imageBuffer, let mask = CornerMask(windowOnly: maskBuffer) {
                let excluded = content.applications.filter { !Self.isInputMethod($0) }
                filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [scWindow])
                configuration.sourceRect = CGRect(
                    x: scWindow.frame.minX - display.frame.minX,
                    y: scWindow.frame.minY - display.frame.minY,
                    width: scWindow.frame.width,
                    height: scWindow.frame.height
                )
                cornerMask = mask
            }
        }
        sink.cornerMask = cornerMask

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
        try await stream.startCapture()

        self.stream = stream
        self.sink = sink
        self.outputURL = url
        self.outputSize = outputSize
        lockWindowSize(window)
        phase = .recording(startedAt: Date())
    }

    // MARK: - 停止

    /// 録画を止めて mp4 を確定させ、`finished` に結果を載せる。
    /// 再生の終了(完走 / 停止ボタン / ESC)から呼ばれる。
    func stop() async {
        guard case .recording = phase, let stream, let sink, let url = outputURL else { return }
        phase = .finishing
        self.stream = nil
        self.sink = nil
        self.outputURL = nil
        unlockWindowSize()

        try? await stream.stopCapture()
        let duration = await sink.finish()

        phase = .idle
        guard let duration, duration > 0 else {
            try? FileManager.default.removeItem(at: url)
            presentAlert(RecorderError.noFrames.localizedDescription,
                         "録画中に書類ウィンドウの更新が一度も検出されませんでした。")
            return
        }
        finished = Recording(url: url, size: outputSize, duration: duration)
    }

    /// トリムシートで破棄されたときなど、素材を捨てる。
    func discard(_ recording: Recording) {
        try? FileManager.default.removeItem(at: recording.url)
        if finished?.id == recording.id { finished = nil }
    }

    // MARK: - ウィンドウサイズの固定
    // SCStreamConfiguration の解像度は固定なので、録画中にリサイズされるとレターボックス化する。

    private func lockWindowSize(_ window: NSWindow) {
        guard window.styleMask.contains(.resizable) else { return }
        window.styleMask.remove(.resizable)
        lockedWindow = window
        restoresResizable = true
    }

    private func unlockWindowSize() {
        if restoresResizable, let lockedWindow {
            lockedWindow.styleMask.insert(.resizable)
        }
        lockedWindow = nil
        restoresResizable = false
    }

    // MARK: - 権限まわり

    /// 入力メソッドのアプリか。`/Library/Input Methods/`・`~/Library/Input Methods/`・
    /// `/System/Library/Input Methods/` のどれかに置かれたアプリを入力メソッドとみなす。
    private static func isInputMethod(_ application: SCRunningApplication) -> Bool {
        guard let path = NSRunningApplication(processIdentifier: application.processID)?.bundleURL?.path
        else { return false }
        return path.contains("/Input Methods/")
    }

    private static func isAuthorizationFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == SCStreamError.errorDomain else { return false }
        return nsError.code == SCStreamError.Code.userDeclined.rawValue
    }

    /// 未許可時の導線。システム設定の「画面収録」ペインを開き、再起動が要る旨も伝える。
    func presentAuthorizationAlert() {
        let alert = NSAlert()
        alert.messageText = "画面収録が許可されていません"
        alert.informativeText = """
        システム設定 →「プライバシーとセキュリティ」→「画面収録」で AWriter を許可してください。

        許可したあとは AWriter を一度終了して起動し直す必要があります。
        """
        alert.addButton(withTitle: "システム設定を開く")
        alert.addButton(withTitle: "閉じる")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func presentAlert(_ message: String, _ informative: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.runModal()
    }

    // MARK: - 補助

    private static func even(_ value: CGFloat) -> Int {
        let rounded = Int(value.rounded())
        return rounded - (rounded % 2)
    }

    /// 角丸の外側を埋める色。地の明暗に合わせる。
    private static func backdrop() -> (b: UInt8, g: UInt8, r: UInt8) {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let level: UInt8 = isDark ? 28 : 255
        return (level, level, level)
    }

    private static func makeOutputURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        .appendingPathComponent("AWriter/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return base.appendingPathComponent("AWriter-\(formatter.string(from: Date())).mp4")
    }

    /// トリム後の既定ファイル名。
    static func suggestedExportName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "AWriter-\(formatter.string(from: Date())).mp4"
    }
}

// MARK: - SCStreamDelegate

extension WindowRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard case .recording = self.phase else { return }
            await self.stop()
            self.presentAlert("録画が中断されました", error.localizedDescription)
        }
    }
}

// MARK: - フレームの受け口と mp4 書き出し

/// SCStream から来る CMSampleBuffer を AVAssetWriter に流す。
/// 専用シリアルキュー上でのみ触られる前提なので `@unchecked Sendable`。
private final class FrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "jp.ac.tmu.baba.AWriter.recorder")

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput

    private var started = false
    private var firstPTS: CMTime = .invalid
    private var lastPTS: CMTime = .invalid
    private var lastImageBuffer: CVImageBuffer?
    private var lastDuration: CMTime = CMTime(value: 1, timescale: 60)
    private var isFinished = false

    /// 角丸の外側を埋める色(BGRA 並び)。
    private let backdrop: (b: UInt8, g: UInt8, r: UInt8)
    /// 透過が出るのは窓の角丸だけなので、上下のこの行数ぶんだけ走査すれば足りる。
    private let cornerBand: Int

    /// 背景合成。nil のときは窓をそのまま書く。
    private let compositor: BackdropCompositor?

    /// 画面ごと撮るときの角丸の形。nil なら窓単体で撮っていて、角はもともと透過で来る。
    /// ストリームを始める前に一度だけ設定する。
    var cornerMask: CornerMask?

    init(url: URL, width: Int, height: Int, backdrop: (b: UInt8, g: UInt8, r: UInt8),
         compositor: BackdropCompositor?) throws {
        self.backdrop = backdrop
        self.compositor = compositor
        self.cornerBand = min(height / 2, max(24, height / 20))
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: H264Settings.video(width: width, height: height))
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw WindowRecorder.RecorderError.noFrames }
        writer.add(input)
        super.init()
        writer.startWriting()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !isFinished else { return }
        // SCK は画面に変化がなくても .idle / .blank のサンプルを流してくる。
        // 中身のないフレームを書くとファイルが壊れるので complete 以外は捨てる。
        guard Self.isComplete(sampleBuffer), let imageBuffer = sampleBuffer.imageBuffer else { return }
        guard input.isReadyForMoreMediaData else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return }

        if !started {
            writer.startSession(atSourceTime: pts)
            firstPTS = pts
            started = true
        }

        cornerMask?.apply(to: imageBuffer)

        let outputBuffer: CVImageBuffer
        if let compositor {
            // 背景を敷くときは角丸の透過をそのまま活かして重ねる(潰してはいけない)
            guard let composited = compositor.composite(imageBuffer) else { return }
            outputBuffer = composited
        } else {
            flattenCorners(imageBuffer)
            outputBuffer = imageBuffer
        }

        let timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        guard let outputSample = compositor == nil
                ? sampleBuffer
                : Self.makeSampleBuffer(outputBuffer, timing: timing),
              input.append(outputSample) else { return }

        lastPTS = pts
        lastImageBuffer = outputBuffer
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if duration.isValid, duration.isNumeric, duration.seconds > 0 { lastDuration = duration }
    }

    /// mp4 を確定させて長さ(秒)を返す。1 フレームも取れていなければ nil。
    func finish() async -> Double? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard !self.isFinished else { return continuation.resume(returning: nil) }
                self.isFinished = true
                guard self.started else {
                    self.writer.cancelWriting()
                    return continuation.resume(returning: nil)
                }

                // 最後の「変化」以降は複製フレームが来ないので、そのまま閉じると末尾の
                // 静止時間が丸ごと落ちる。最後の絵を停止時刻の PTS で 1 枚足しておく。
                let end = self.appendTailFrame()
                self.input.markAsFinished()
                self.writer.endSession(atSourceTime: end)
                self.writer.finishWriting {
                    let duration = (end - self.firstPTS).seconds
                    continuation.resume(returning: self.writer.status == .completed ? duration : nil)
                }
            }
        }
    }

    /// 停止時刻ぶんだけ末尾を伸ばす。伸ばした先の時刻を返す。
    private func appendTailFrame() -> CMTime {
        let naturalEnd = lastPTS + lastDuration
        guard let imageBuffer = lastImageBuffer, lastPTS.isValid else { return naturalEnd }

        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let target = CMTimeConvertScale(now, timescale: lastPTS.timescale, method: .roundHalfAwayFromZero)
        guard target > naturalEnd else { return naturalEnd }

        let timing = CMSampleTimingInfo(
            duration: lastDuration,
            presentationTimeStamp: target,
            decodeTimeStamp: .invalid
        )
        guard let tail = Self.makeSampleBuffer(imageBuffer, timing: timing),
              input.isReadyForMoreMediaData, input.append(tail) else {
            return naturalEnd
        }
        return target + lastDuration
    }

    private static func makeSampleBuffer(_ imageBuffer: CVImageBuffer, timing: CMSampleTimingInfo) -> CMSampleBuffer? {
        var format: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: imageBuffer, formatDescriptionOut: &format
        ) == noErr, let format else { return nil }

        var timing = timing
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }

    /// `desktopIndependentWindow` のキャプチャは窓の角丸を透過(A=0、premultiplied で RGB=0)で
    /// 返す。H.264 はアルファを落とすので、そのまま渡すと四隅が黒く抜ける。
    /// 上下の帯だけを走査し、premultiplied source-over で下地の色を敷いておく。
    private func flattenCorners(_ pixelBuffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess
        else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        let band = min(cornerBand, height)

        for row in 0..<height where row < band || row >= height - band {
            let line = pointer + row * bytesPerRow
            for column in 0..<width {
                let pixel = line + column * 4
                let alpha = pixel[3]
                if alpha == 255 { continue }
                // premultiplied なので src はそのまま足せる
                let inverse = Int(255 - alpha)
                pixel[0] = UInt8(min(255, Int(pixel[0]) + Int(backdrop.b) * inverse / 255))
                pixel[1] = UInt8(min(255, Int(pixel[1]) + Int(backdrop.g) * inverse / 255))
                pixel[2] = UInt8(min(255, Int(pixel[2]) + Int(backdrop.r) * inverse / 255))
                pixel[3] = 255
            }
        }
    }

    private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }
}

// MARK: - 角丸の形

/// 書類窓の角丸の外側の透過(アルファ)。窓だけを撮った 1 枚から上下の帯ぶんを取っておき、
/// 画面ごと撮ったフレームの角に当てる。録画中は窓の大きさを固定するので形は変わらない。
struct CornerMask: @unchecked Sendable {
    let width: Int
    let height: Int
    let band: Int
    /// 上の帯 band 行 → 下の帯 band 行の順に、1 画素 1 バイトのアルファ。
    private let alphas: [UInt8]

    init?(windowOnly pixelBuffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess
        else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let band = min(height / 2, max(24, height / 20))
        let pointer = base.assumingMemoryBound(to: UInt8.self)

        var alphas = [UInt8](repeating: 255, count: band * 2 * width)
        var hasTransparency = false
        for index in 0..<(band * 2) {
            let row = index < band ? index : height - band * 2 + index
            let line = pointer + row * bytesPerRow
            for column in 0..<width {
                let alpha = line[column * 4 + 3]
                alphas[index * width + column] = alpha
                if alpha < 255 { hasTransparency = true }
            }
        }
        // 透過が 1 画素もない(角丸のない窓、または取り損ね)なら当てても意味がない。
        guard hasTransparency else { return nil }
        self.width = width
        self.height = height
        self.band = band
        self.alphas = alphas
    }

    /// 角の外側を窓だけのときと同じ透過にする(premultiplied のまま色も同じ比で落とす)。
    /// 角の外が既に透過で来ていれば何も変わらない。黒などで埋まって来たときに効く。
    func apply(to pixelBuffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(pixelBuffer) == width,
              CVPixelBufferGetHeight(pixelBuffer) == height,
              CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess
        else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        for index in 0..<(band * 2) {
            let row = index < band ? index : height - band * 2 + index
            let line = pointer + row * bytesPerRow
            for column in 0..<width {
                let mask = Int(alphas[index * width + column])
                if mask == 255 { continue }
                let pixel = line + column * 4
                let alpha = Int(pixel[3])
                if alpha <= mask { continue }
                pixel[0] = UInt8(Int(pixel[0]) * mask / alpha)
                pixel[1] = UInt8(Int(pixel[1]) * mask / alpha)
                pixel[2] = UInt8(Int(pixel[2]) * mask / alpha)
                pixel[3] = UInt8(mask)
            }
        }
    }
}
