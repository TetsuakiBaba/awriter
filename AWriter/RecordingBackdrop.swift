import AppKit
import CoreImage

/// 録画に付ける背景の設定。teaser.mp4 のように、書類ウィンドウを壁紙の上に
/// 余白付きで浮かせた絵を作るためのもの。
struct BackdropSettings {
    var isEnabled: Bool
    /// 背景を画像で敷くか単色で塗るか。
    var fill: BackdropFill
    /// コンテナ内にコピーした背景画像。nil ならグラデーションで代用する。
    var imagePath: String?
    /// `fill == .color` のときの背景色("#RRGGBB")。
    var colorHex: String
    /// 余白。キャンバスに対する左右上下それぞれの比率。
    var marginRatio: Double
    var showsShadow: Bool
    var aspect: BackdropAspect

    static let enabledKey = "backdropEnabled"
    static let fillKey = "backdropFill"
    static let imagePathKey = "backdropImagePath"
    static let colorKey = "backdropColor"
    static let marginKey = "backdropMargin"
    static let shadowKey = "backdropShadow"
    static let aspectKey = "backdropAspect"

    static let defaultMargin = 0.08
    static let defaultColorHex = "#1F2D33"

    static var stored: BackdropSettings {
        let defaults = UserDefaults.standard
        return BackdropSettings(
            isEnabled: defaults.bool(forKey: enabledKey),
            fill: BackdropFill(rawValue: defaults.string(forKey: fillKey) ?? "") ?? .image,
            imagePath: defaults.string(forKey: imagePathKey),
            colorHex: defaults.string(forKey: colorKey) ?? defaultColorHex,
            marginRatio: defaults.object(forKey: marginKey) as? Double ?? defaultMargin,
            showsShadow: defaults.object(forKey: shadowKey) as? Bool ?? true,
            aspect: BackdropAspect(rawValue: defaults.string(forKey: aspectKey) ?? "") ?? .sixteenNine
        )
    }

    /// 背景画像を置く場所。サンドボックスの外を毎回開き直さずに済むよう、
    /// 選ばれた画像はここにコピーする(ブックマークを持たなくてよい)。
    static func imageStoreURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        .appendingPathComponent("AWriter/Backdrops", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}

enum BackdropFill: String, CaseIterable, Identifiable {
    case image
    case color

    var id: String { rawValue }

    var label: String {
        switch self {
        case .image: return "画像"
        case .color: return "単色"
        }
    }
}

/// キャンバスの寸法と、その中での窓の位置。合成と設定画面のプレビューで同じ計算を使う。
struct BackdropGeometry {
    let canvasSize: CGSize
    let windowRect: CGRect

    /// 窓を等倍で置ける最小のキャンバスを求め、指定の縦横比まで広げる。
    static func make(windowPixelSize: CGSize, settings: BackdropSettings) -> BackdropGeometry? {
        guard windowPixelSize.width > 0, windowPixelSize.height > 0 else { return nil }

        let margin = min(0.4, max(0, settings.marginRatio))
        let usable = 1 - margin * 2
        guard usable > 0.1 else { return nil }

        let neededWidth = windowPixelSize.width / usable
        let neededHeight = windowPixelSize.height / usable
        var width: Double
        var height: Double
        if let ratio = settings.aspect.ratio {
            width = max(neededWidth, neededHeight * ratio)
            height = width / ratio
        } else {
            width = neededWidth
            height = neededHeight
        }
        // H.264 は偶数寸法を要求する
        let canvas = CGSize(width: Double(Int(width.rounded()) & ~1), height: Double(Int(height.rounded()) & ~1))
        let origin = CGPoint(
            x: ((canvas.width - windowPixelSize.width) / 2).rounded(),
            y: ((canvas.height - windowPixelSize.height) / 2).rounded()
        )
        return BackdropGeometry(canvasSize: canvas, windowRect: CGRect(origin: origin, size: windowPixelSize))
    }

    /// macOS のウィンドウ角丸を、キャプチャの実ピクセルに換算した値。
    var cornerRadius: CGFloat { min(windowRect.height / 8, 24) }
}

enum BackdropAspect: String, CaseIterable, Identifiable {
    case sixteenNine
    case sixteenTen
    case fourThree
    case source

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sixteenNine: return "16:9"
        case .sixteenTen: return "16:10"
        case .fourThree: return "4:3"
        case .source: return "ウィンドウに合わせる"
        }
    }

    /// 幅 / 高さ。`.source` はウィンドウの比をそのまま使うので nil。
    var ratio: Double? {
        switch self {
        case .sixteenNine: return 16.0 / 9.0
        case .sixteenTen: return 16.0 / 10.0
        case .fourThree: return 4.0 / 3.0
        case .source: return nil
        }
    }
}

/// キャプチャした窓(角丸が透過で入っている)を、背景と影の上に重ねて 1 枚の絵にする。
///
/// 背景と影は録画中ずっと変わらないので、開始時に一度だけ焼き込んでおき、
/// 毎フレームの仕事は「窓を所定の位置に重ねて出力バッファに描く」だけにしている。
/// 窓は等倍のまま置く(縮小しないので文字が滲まない)。
final class BackdropCompositor {
    let canvasSize: CGSize

    private let context: CIContext
    private let backdrop: CIImage
    private let windowOrigin: CGPoint
    private var pool: CVPixelBufferPool?

    /// - Parameter windowPixelSize: キャプチャの実ピクセルサイズ。
    init?(windowPixelSize: CGSize, settings: BackdropSettings) {
        guard let geometry = BackdropGeometry.make(windowPixelSize: windowPixelSize, settings: settings) else {
            return nil
        }
        canvasSize = geometry.canvasSize
        windowOrigin = geometry.windowRect.origin

        context = CIContext(options: [.cacheIntermediates: false])

        guard let baked = Self.bake(geometry: geometry, settings: settings) else { return nil }
        backdrop = CIImage(cgImage: baked)

        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(canvasSize.width),
            kCVPixelBufferHeightKey as String: Int(canvasSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess
        else { return nil }
        self.pool = pool
    }

    /// 窓のフレームを背景の上に重ねた新しいピクセルバッファを返す。
    func composite(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination) == kCVReturnSuccess,
              let destination else { return nil }

        let window = CIImage(cvPixelBuffer: source)
            .transformed(by: CGAffineTransform(translationX: windowOrigin.x, y: windowOrigin.y))
        context.render(window.composited(over: backdrop), to: destination)
        return destination
    }

    // MARK: - 背景と影の焼き込み

    private static func bake(geometry: BackdropGeometry, settings: BackdropSettings) -> CGImage? {
        let canvasSize = geometry.canvasSize
        let windowRect = geometry.windowRect
        guard let context = CGContext(
            data: nil,
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        let canvas = CGRect(origin: .zero, size: canvasSize)
        switch settings.fill {
        case .color:
            context.setFillColor((NSColor(hex: settings.colorHex) ?? .black).cgColor)
            context.fill(canvas)
        case .image:
            if let image = settings.imagePath.flatMap(loadImage) {
                context.draw(image, in: aspectFill(image: CGSize(width: image.width, height: image.height), into: canvas))
            } else {
                drawFallbackGradient(in: context, canvas: canvas)
            }
        }

        if settings.showsShadow {
            // 窓のシルエット(角丸矩形)ぶんだけ影を落とす。窓自体はこのあと重ねるので、
            // ここで塗る色は見えない。
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -canvasSize.height * 0.012),
                blur: canvasSize.height * 0.035,
                color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45)
            )
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.addPath(CGPath(
                roundedRect: windowRect.insetBy(dx: 1, dy: 1),
                cornerWidth: geometry.cornerRadius,
                cornerHeight: geometry.cornerRadius,
                transform: nil
            ))
            context.fillPath()
            context.restoreGState()
        }

        return context.makeImage()
    }

    private static func loadImage(_ path: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 画像をキャンバスいっぱいに、比を保ったまま(はみ出す分は切って)敷く矩形。
    private static func aspectFill(image: CGSize, into canvas: CGRect) -> CGRect {
        guard image.width > 0, image.height > 0 else { return canvas }
        let scale = max(canvas.width / image.width, canvas.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(
            x: canvas.midX - size.width / 2,
            y: canvas.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// 背景画像が選ばれていないときの代用。
    private static func drawFallbackGradient(in context: CGContext, canvas: CGRect) {
        let colors = [
            CGColor(red: 0.16, green: 0.25, blue: 0.28, alpha: 1),
            CGColor(red: 0.05, green: 0.09, blue: 0.11, alpha: 1),
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])
        else {
            context.setFillColor(CGColor(gray: 0.1, alpha: 1))
            context.fill(canvas)
            return
        }
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: canvas.midX, y: canvas.maxY),
            end: CGPoint(x: canvas.midX, y: canvas.minY),
            options: []
        )
    }
}
