import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - 設定

enum KeystrokeSettings {
    static let enabledKey = "keycastEnabled"
    static let modeKey = "keycastMode"
    static let positionKey = "keycastPosition"
    static let sizeKey = "keycastSize"
    static let durationKey = "keycastDuration"

    static let defaultSize: Double = 22
    static let defaultDuration: Double = 1.6
}

enum KeystrokeMode: String, CaseIterable, Identifiable {
    case all
    case specialOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "すべてのキー"
        case .specialOnly: return "特殊キーのみ"
        }
    }

    var help: String {
        switch self {
        case .all: return "ローマ字入力もひと続きの札にまとめて表示する"
        case .specialOnly: return "修飾キー付きの操作と特殊キーだけを表示する"
        }
    }
}

enum KeystrokePosition: String, CaseIterable, Identifiable {
    case caret
    case bottomLeading
    case bottom
    case bottomTrailing
    case top

    var id: String { rawValue }

    var label: String {
        switch self {
        case .caret: return "カーソル位置"
        case .bottomLeading: return "左下"
        case .bottom: return "下中央"
        case .bottomTrailing: return "右下"
        case .top: return "上中央"
        }
    }

    var followsCaret: Bool { self == .caret }

    /// 固定表示のときの寄せ位置。カーソル追従では使わない。
    var alignment: Alignment {
        switch self {
        case .caret, .bottom: return .bottom
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        case .top: return .top
        }
    }
}

// MARK: - 表示モデル

/// 押されたキーを札にして一定時間だけ並べる。
/// 台本再生の合成キーも実キーも `AWTextView.keyDown` を通るので、両方まとめてここに届く。
@MainActor
final class KeystrokeOverlay: ObservableObject {
    static let shared = KeystrokeOverlay()

    struct Cue: Identifiable, Equatable {
        let id: UUID
        var text: String
        let isPlain: Bool
    }

    @Published private(set) var cues: [Cue] = []

    /// 挿入点の矩形。スクロールビュー内(左上原点・下向き y)の座標。
    @Published var caretRect: CGRect = .zero

    /// カーソル追従表示のときだけ挿入点を追いかける。
    static var followsCaret: Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: KeystrokeSettings.enabledKey) else { return false }
        let raw = defaults.string(forKey: KeystrokeSettings.positionKey) ?? ""
        return (KeystrokePosition(rawValue: raw) ?? .bottom).followsCaret
    }

    private var expiryTasks: [UUID: Task<Void, Never>] = [:]
    private static let maxCues = 10
    private static let maxPlainLength = 20

    private init() {}

    func report(_ event: NSEvent) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: KeystrokeSettings.enabledKey) else { return }
        guard let described = KeystrokeFormatter.describe(event) else { return }

        let mode = KeystrokeMode(rawValue: defaults.string(forKey: KeystrokeSettings.modeKey) ?? "") ?? .all
        if mode == .specialOnly, described.isPlain { return }

        push(text: described.text, isPlain: described.isPlain)
    }

    func clear() {
        expiryTasks.values.forEach { $0.cancel() }
        expiryTasks.removeAll()
        cues.removeAll()
    }

    /// 連続する通常文字はひと続きの札に伸ばす(ローマ字が溜まっていく様子が見える)。
    private func push(text: String, isPlain: Bool) {
        if isPlain,
           let last = cues.last,
           last.isPlain,
           last.text.count < Self.maxPlainLength {
            cues[cues.count - 1].text += text
            scheduleExpiry(for: last.id)
            return
        }

        let cue = Cue(id: UUID(), text: text, isPlain: isPlain)
        cues.append(cue)
        while cues.count > Self.maxCues {
            let dropped = cues.removeFirst()
            expiryTasks.removeValue(forKey: dropped.id)?.cancel()
        }
        scheduleExpiry(for: cue.id)
    }

    private func scheduleExpiry(for id: UUID) {
        expiryTasks[id]?.cancel()
        let stored = UserDefaults.standard.double(forKey: KeystrokeSettings.durationKey)
        let seconds = stored > 0 ? stored : KeystrokeSettings.defaultDuration
        expiryTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.remove(id)
        }
    }

    private func remove(_ id: UUID) {
        cues.removeAll { $0.id == id }
        expiryTasks.removeValue(forKey: id)
    }
}

// MARK: - キーの見せ方

enum KeystrokeFormatter {
    /// 表示文字列と、通常文字かどうか。表示しないキーは nil。
    static func describe(_ event: NSEvent) -> (text: String, isPlain: Bool)? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let option = flags.contains(.option)
        let control = flags.contains(.control)
        let shift = flags.contains(.shift)

        var prefix = ""
        if control { prefix += "⌃" }
        if option { prefix += "⌥" }
        if shift { prefix += "⇧" }
        if command { prefix += "⌘" }

        if let special = specialSymbol(for: event.keyCode) {
            return (prefix + special, false)
        }

        guard let base = event.charactersIgnoringModifiers, !base.isEmpty,
              let scalar = base.unicodeScalars.first,
              scalar.value >= 0x20, scalar.value != 0x7F
        else { return nil }

        if command || option || control {
            return (prefix + base.uppercased(), false)
        }

        // Shift だけなら「⇧A」ではなく打たれた文字そのものを見せる
        return (event.characters ?? base, true)
    }

    private static func specialSymbol(for keyCode: UInt16) -> String? {
        switch Int(keyCode) {
        case kVK_Return: return "↩"
        case kVK_ANSI_KeypadEnter: return "⌤"
        case kVK_Space: return "␣"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_JIS_Kana: return "かな"
        case kVK_JIS_Eisu: return "英数"
        default: return nil
        }
    }
}

// MARK: - 表示

struct KeystrokeOverlayView: View {
    @ObservedObject private var overlay = KeystrokeOverlay.shared
    @AppStorage(KeystrokeSettings.sizeKey) private var size: Double = KeystrokeSettings.defaultSize

    var body: some View {
        HStack(spacing: size * 0.34) {
            ForEach(overlay.cues) { cue in
                chip(cue.text)
            }
        }
        .animation(.spring(response: 0.26, dampingFraction: 0.82), value: overlay.cues)
        .allowsHitTesting(false)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: size, weight: .medium, design: .rounded))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, size * 0.52)
            .padding(.vertical, size * 0.28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: size * 0.42))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.42)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: size * 0.18, y: size * 0.06)
            .transition(.opacity.combined(with: .scale(scale: 0.86)))
    }
}

/// 挿入点のすぐ下に札を出す。はみ出しそうなら内側へ寄せ、下に入らなければ上に回す。
struct CaretKeystrokeOverlay: View {
    @ObservedObject private var overlay = KeystrokeOverlay.shared
    @State private var cueSize: CGSize = .zero

    private let margin: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            KeystrokeOverlayView()
                .background(
                    GeometryReader { inner in
                        Color.clear.preference(key: CueSizeKey.self, value: inner.size)
                    }
                )
                .offset(x: originX(in: proxy.size), y: originY(in: proxy.size))
                .animation(.easeOut(duration: 0.12), value: overlay.caretRect)
        }
        .onPreferenceChange(CueSizeKey.self) { cueSize = $0 }
    }

    private func originX(in container: CGSize) -> CGFloat {
        let upperBound = max(margin, container.width - cueSize.width - margin)
        return min(max(margin, overlay.caretRect.minX), upperBound)
    }

    private func originY(in container: CGSize) -> CGFloat {
        let below = overlay.caretRect.maxY + margin
        if below + cueSize.height + margin <= container.height {
            return below
        }
        return max(margin, overlay.caretRect.minY - cueSize.height - margin)
    }
}

private struct CueSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

// MARK: - 設定パネル(台本エディタから開く)

struct KeystrokeSettingsPanel: View {
    @AppStorage(KeystrokeSettings.enabledKey) private var enabled: Bool = false
    @AppStorage(KeystrokeSettings.modeKey) private var mode: String = KeystrokeMode.all.rawValue
    @AppStorage(KeystrokeSettings.positionKey) private var position: String = KeystrokePosition.bottom.rawValue
    @AppStorage(KeystrokeSettings.sizeKey) private var size: Double = KeystrokeSettings.defaultSize
    @AppStorage(KeystrokeSettings.durationKey) private var duration: Double = KeystrokeSettings.defaultDuration

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("キー入力をエディタに表示", isOn: $enabled)
                .font(.system(size: 13, weight: .semibold))
                .onChange(of: enabled) { _, isOn in
                    if !isOn { KeystrokeOverlay.shared.clear() }
                }

            Text("押されたキーを札にして重ねます。⇧↩ のように修飾キーも見えるので、映像を見ている人に操作が伝わります。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                label("表示するキー")
                Picker("", selection: $mode) {
                    ForEach(KeystrokeMode.allCases) { item in
                        Text(item.label).tag(item.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(KeystrokeMode(rawValue: mode)?.help ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                label("位置")
                Picker("", selection: $position) {
                    ForEach(KeystrokePosition.allCases) { item in
                        Text(item.label).tag(item.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                if KeystrokePosition(rawValue: position)?.followsCaret == true {
                    Text("入力中の挿入点のすぐ下に付いて動きます。端に寄ると自動で内側に収まります。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                label("大きさ")
                HStack(spacing: 10) {
                    Slider(value: $size, in: 14...44, step: 1)
                    Text("\(Int(size))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .trailing)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                label("残す時間")
                HStack(spacing: 10) {
                    Slider(value: $duration, in: 0.5...5, step: 0.1)
                    Text(String(format: "%.1f 秒", duration))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
