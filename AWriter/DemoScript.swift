import Foundation

/// 撮影用の台本(.keys)。ディレクティブ+キー入力列をパースする。
///
/// ```
/// # コメント
/// #lead 3          … 再生開始までの秒数
/// #interval 90     … 基本キー間隔 ms
/// #jitter 0.3      … 間隔のゆらぎ率
/// #speed 1.0       … 全体速度倍率
///
/// yamamichi{space}{enter}
/// ```
/// 生改行はキーを送らない。改行キーは {enter} で明示する。
struct DemoScript {
    enum SpecialKey: String {
        case enter, space, tab, esc, bs, up, down, left, right
        case kana, eisu
    }

    struct Modifiers: OptionSet {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1 << 0)
        static let shift = Modifiers(rawValue: 1 << 1)
        static let option = Modifiers(rawValue: 1 << 2)
        static let control = Modifiers(rawValue: 1 << 3)
    }

    enum Step {
        case character(Character)
        case special(SpecialKey, Modifiers)
        case shortcut(Character, Modifiers)
        case wait(TimeInterval)
    }

    var lead: TimeInterval = 3
    var interval: TimeInterval = 0.09
    var jitter: Double = 0.3
    var speed: Double = 1
    var steps: [Step] = []

    enum ParseError: LocalizedError {
        case unterminatedToken(line: Int)
        case unknownToken(String, line: Int)

        var errorDescription: String? {
            switch self {
            case .unterminatedToken(let line):
                return "\(line)行目: { が } で閉じられていません"
            case .unknownToken(let token, let line):
                return "\(line)行目: 不明なトークン {\(token)}"
            }
        }
    }

    init(source: String) throws {
        for (index, rawLine) in source.components(separatedBy: .newlines).enumerated() {
            let lineNumber = index + 1
            if rawLine.hasPrefix("#") {
                applyDirective(rawLine)
                continue
            }
            var rest = Substring(rawLine)
            while let character = rest.first {
                if character == "{" {
                    guard let close = rest.firstIndex(of: "}") else {
                        throw ParseError.unterminatedToken(line: lineNumber)
                    }
                    let token = rest[rest.index(after: rest.startIndex)..<close]
                    try appendToken(String(token), line: lineNumber)
                    rest = rest[rest.index(after: close)...]
                } else {
                    steps.append(.character(character))
                    rest = rest.dropFirst()
                }
            }
        }
    }

    /// 既知のディレクティブ以外の # 行はコメントとして無視する。
    private mutating func applyDirective(_ line: String) {
        let parts = line.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        switch parts[0].lowercased() {
        case "lead":
            lead = Double(value) ?? lead
        case "interval":
            if let ms = Double(value) { interval = ms / 1000 }
        case "jitter":
            jitter = Double(value) ?? jitter
        case "speed":
            if let v = Double(value) { speed = max(0.1, v) }
        default:
            break
        }
    }

    private static let specialAliases: [String: SpecialKey] = [
        "return": .enter,
        "escape": .esc,
        "delete": .bs,
        "backspace": .bs,
    ]

    private mutating func appendToken(_ raw: String, line: Int) throws {
        let token = raw.trimmingCharacters(in: .whitespaces).lowercased()

        if token.hasPrefix("wait") {
            let value = token.dropFirst(4).trimmingCharacters(in: .whitespaces)
            guard let seconds = Double(value), seconds >= 0 else {
                throw ParseError.unknownToken(raw, line: line)
            }
            steps.append(.wait(seconds))
            return
        }

        let parts = token.split(separator: "+").map(String.init)
        guard let keyPart = parts.last, !keyPart.isEmpty else {
            throw ParseError.unknownToken(raw, line: line)
        }
        var modifiers: Modifiers = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "opt", "option", "alt": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            default: throw ParseError.unknownToken(raw, line: line)
            }
        }

        if let special = SpecialKey(rawValue: keyPart) ?? Self.specialAliases[keyPart] {
            steps.append(.special(special, modifiers))
        } else if keyPart.count == 1 {
            steps.append(.shortcut(Character(keyPart), modifiers))
        } else {
            throw ParseError.unknownToken(raw, line: line)
        }
    }
}
