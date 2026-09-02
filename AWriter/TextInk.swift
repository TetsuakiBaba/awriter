import AppKit

/// 文字色。"auto" はラベルカラー(ライト/ダークに追従)、それ以外は "#RRGGBB"。
enum TextInk {
    static let automaticID = "auto"

    struct Swatch: Identifiable {
        let id: String
        let name: String
    }

    static let swatches: [Swatch] = [
        Swatch(id: automaticID, name: "自動"),
        Swatch(id: "#1C1C1E", name: "墨"),
        Swatch(id: "#595144", name: "煤竹"),
        Swatch(id: "#274A78", name: "紺青"),
        Swatch(id: "#6D2E2A", name: "海老茶"),
        Swatch(id: "#2D4A3E", name: "千歳緑"),
        Swatch(id: "#EDE9DE", name: "胡粉"),
    ]

    static func nsColor(for id: String) -> NSColor {
        if id == automaticID { return .labelColor }
        return NSColor(hex: id) ?? .labelColor
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var string = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasPrefix("#") { string.removeFirst() }
        guard string.count == 6, let value = UInt32(string, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        return String(
            format: "#%02X%02X%02X",
            Int(round(color.redComponent * 255)),
            Int(round(color.greenComponent * 255)),
            Int(round(color.blueComponent * 255))
        )
    }

    /// 変換中テキストの下線。アクセントの色味を本文に持ち込まない。
    static let compositionUnderline = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(white: 0.82, alpha: 1)
        } else {
            return NSColor(white: 0.18, alpha: 1)
        }
    }

    /// 変換中クローズと選択範囲の地。無彩色の薄い墨。
    static let compositionFill = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(white: 1, alpha: 0.17)
        } else {
            return NSColor(white: 0, alpha: 0.11)
        }
    }

    /// 本文の背景。ライトでは暖かみのある紙色、ダークでは焦げ茶がかった黒。
    static let paper = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(srgbRed: 0.106, green: 0.102, blue: 0.098, alpha: 1)
        } else {
            return NSColor(srgbRed: 0.988, green: 0.984, blue: 0.972, alpha: 1)
        }
    }
}
