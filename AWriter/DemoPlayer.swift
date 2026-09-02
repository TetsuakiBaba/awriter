import AppKit
import Carbon.HIToolbox

/// 台本のキー入力列を合成 NSEvent として自アプリのイベントキューに投入する再生エンジン。
/// イベントは通常のキー入力と同一経路(key window → NSTextView → NSTextInputContext)を
/// 通るため、かな合成・変換・候補選択・確定はすべて本物の IME が行う。
@MainActor
final class DemoPlayer: ObservableObject {
    static let shared = DemoPlayer()

    /// 再生の進行状況。UI(台本エディタのバナー / フローティング HUD)が購読する。
    enum Phase: Equatable {
        case idle
        case countdown(remaining: Int)
        case playing(completed: Int, total: Int)

        var isActive: Bool { self != .idle }

        var headline: String {
            switch self {
            case .idle:
                return ""
            case .countdown(let remaining):
                return "\(remaining) 秒後に開始"
            case .playing(let completed, let total):
                return "再生中  \(completed) / \(total)"
            }
        }

        var progress: Double? {
            guard case .playing(let completed, let total) = self, total > 0 else { return nil }
            return Double(completed) / Double(total)
        }
    }

    @Published private(set) var phase: Phase = .idle

    private var playbackTask: Task<Void, Never>?
    private var monitor: Any?
    private var generation = 0
    /// 再生の終了(完走 / 停止ボタン / ESC)を呼び出し側に伝える。録画の自動停止に使う。
    private var completion: (() -> Void)?

    private init() {}

    // MARK: - 起動口

    func playBundledSample() {
        guard let url = Bundle.main.url(forResource: "sample", withExtension: "keys") else {
            presentAlert("サンプルが見つかりません", "アプリにバンドルされた sample.keys がありません。")
            return
        }
        play(contentsOf: url)
    }

    private func play(contentsOf url: URL) {
        do {
            let source = try String(contentsOf: url, encoding: .utf8)
            let script = try DemoScript(source: source)
            play(script)
        } catch {
            presentAlert("台本を読み込めませんでした", error.localizedDescription)
        }
    }

    /// - Parameter completion: 再生がどう終わっても(完走・停止・ESC)一度だけ呼ばれる。
    func play(_ script: DemoScript, clearingDocument: Bool = false, completion: (() -> Void)? = nil) {
        // 先に stop() を通すので、completion の代入はそのあとで行う。
        stop()
        guard let textView = targetTextView() else {
            presentAlert("書類ウィンドウがありません", "再生先の書類を開いてから実行してください。")
            completion?()
            return
        }
        if clearingDocument {
            Self.clearDocument(textView)
        }
        guard let map = KeyboardMap.current() else {
            presentAlert("キーボード配列を取得できませんでした", "再生を開始できません。")
            completion?()
            return
        }
        generation += 1
        let gen = generation
        self.completion = completion
        installMonitor()
        phase = .countdown(remaining: Int(script.lead.rounded(.up)))
        PlaybackHUD.show()
        playbackTask = Task { [weak self] in
            await self?.run(script, map: map, textView: textView)
            self?.finish(generation: gen)
        }
    }

    func stop() {
        playbackTask?.cancel()
        playbackTask = nil
        removeMonitor()
        phase = .idle
        PlaybackHUD.hide()
        notifyCompletion()
    }

    private func finish(generation gen: Int) {
        guard gen == generation else { return }
        playbackTask = nil
        removeMonitor()
        phase = .idle
        PlaybackHUD.hide()
        notifyCompletion()
    }

    private func notifyCompletion() {
        let completion = self.completion
        self.completion = nil
        completion?()
    }

    // MARK: - 再生ループ

    private func run(_ script: DemoScript, map: KeyboardMap, textView: NSTextView) async {
        do {
            var lead = script.lead
            while lead > 0 {
                phase = .countdown(remaining: Int(lead.rounded(.up)))
                let tick = min(1, lead)
                try await Task.sleep(for: .seconds(tick))
                lead -= tick
            }
            let total = script.steps.count
            for (index, step) in script.steps.enumerated() {
                try Task.checkCancellation()
                phase = .playing(completed: index, total: total)
                switch step {
                case .wait(let seconds):
                    try await Task.sleep(for: .seconds(seconds / script.speed))
                case .character(let character):
                    guard let spec = map.spec(for: character) else { continue }
                    try await post(spec, script: script, textView: textView)
                case .special(let key, let modifiers):
                    let spec = KeyboardMap.spec(for: key).adding(Self.flags(from: modifiers))
                    try await post(spec, script: script, textView: textView)
                case .shortcut(let character, let modifiers):
                    guard let base = map.spec(for: character) else { continue }
                    try await post(base.adding(Self.flags(from: modifiers)), script: script, textView: textView)
                }
            }
            phase = .playing(completed: total, total: total)
        } catch {
            // キャンセル(停止/ESC)
        }
    }

    private func post(_ spec: KeySpec, script: DemoScript, textView: NSTextView) async throws {
        guard textView.window != nil else { throw CancellationError() }
        // sendEvent で同期的に流す(postEvent のキュー経由だと IME 処理と
        // 順序が乱れてキーが失われることがある)
        if let down = makeEvent(keyDown: true, spec: spec) {
            NSApp.sendEvent(down)
        }
        try await Task.sleep(for: .seconds(0.025))
        if let up = makeEvent(keyDown: false, spec: spec) {
            NSApp.sendEvent(up)
        }
        let base = script.interval / script.speed
        let jitter = 1 + Double.random(in: -script.jitter...script.jitter)
        try await Task.sleep(for: .seconds(max(0.015, base * jitter)))
    }

    /// CGEvent の裏付けを持つ NSEvent を作る。裏付けのないイベントは
    /// TSM(IME)が処理せず、かな合成が起きないため必須。
    private func makeEvent(keyDown: Bool, spec: KeySpec) -> NSEvent? {
        guard let cgEvent = CGEvent(
            keyboardEventSource: CGEventSource(stateID: .combinedSessionState),
            virtualKey: CGKeyCode(spec.keyCode),
            keyDown: keyDown
        ) else { return nil }
        cgEvent.timestamp = CGEventTimestamp(DispatchTime.now().uptimeNanoseconds)
        var flags: CGEventFlags = []
        if spec.flags.contains(.shift) { flags.insert(.maskShift) }
        if spec.flags.contains(.command) { flags.insert(.maskCommand) }
        if spec.flags.contains(.option) { flags.insert(.maskAlternate) }
        if spec.flags.contains(.control) { flags.insert(.maskControl) }
        if spec.flags.contains(.function) { flags.insert(.maskSecondaryFn) }
        if spec.flags.contains(.numericPad) { flags.insert(.maskNumericPad) }
        cgEvent.flags = flags
        return NSEvent(cgEvent: cgEvent)
    }

    // MARK: - ESC での停止(再生中はキーボードに触れない運用が前提)
    // 合成イベントは sendEvent 直送のためローカルモニタを通らず、
    // ここに届く ESC は実打鍵のみ。

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            MainActor.assumeIsolated {
                if event.keyCode == UInt16(kVK_Escape) {
                    DemoPlayer.shared.stop()
                    return nil
                }
                return event
            }
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    // MARK: - 補助

    /// 再撮り用に本文を空にする。通常の編集として行うので ⌘Z で元に戻せる。
    private static func clearDocument(_ textView: NSTextView) {
        let range = NSRange(location: 0, length: (textView.string as NSString).length)
        guard range.length > 0, textView.shouldChangeText(in: range, replacementString: "") else {
            return
        }
        textView.textStorage?.replaceCharacters(in: range, with: "")
        textView.didChangeText()
    }

    /// 最前面の「書類ウィンドウ」(AWTextView を含むウィンドウ)を探して前面化する。
    /// 台本エディタなど他のウィンドウから再生しても、打鍵は書類に届く。
    private func targetTextView() -> NSTextView? {
        for window in NSApp.orderedWindows {
            guard let textView = Self.findTextView(in: window.contentView) else { continue }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(textView)
            return textView
        }
        return nil
    }

    /// 「書類ウィンドウ」を副作用なしで探す(前面化も firstResponder 変更もしない)。
    /// 録画対象の特定に使う。
    static func documentWindow() -> NSWindow? {
        NSApp.orderedWindows.first { findTextView(in: $0.contentView) != nil }
    }

    private static func findTextView(in view: NSView?) -> AWTextView? {
        guard let view else { return nil }
        if let textView = view as? AWTextView { return textView }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
    }

    private func presentAlert(_ message: String, _ informative: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.runModal()
    }

    private static func flags(from modifiers: DemoScript.Modifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }
}

// MARK: - キーイベント仕様

struct KeySpec {
    let keyCode: UInt16
    let characters: String
    let charactersIgnoringModifiers: String
    let flags: NSEvent.ModifierFlags

    func adding(_ extra: NSEvent.ModifierFlags) -> KeySpec {
        KeySpec(
            keyCode: keyCode,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            flags: flags.union(extra)
        )
    }
}

// MARK: - 物理配列に追従するキーコード逆引き

final class KeyboardMap {
    private var plain: [Character: UInt16] = [:]
    private var shifted: [Character: UInt16] = [:]
    private var plainByCode: [UInt16: Character] = [:]

    static func current() -> KeyboardMap? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let dataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(dataPointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        let map = KeyboardMap()
        let keyboardType = UInt32(LMGetKbdType())
        let shiftState = UInt32((shiftKey >> 8) & 0xFF)
        for keyCode: UInt16 in 0..<128 {
            for (modifierState, isShifted) in [(UInt32(0), false), (shiftState, true)] {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout, keyCode, UInt16(kUCKeyActionDown), modifierState,
                    keyboardType, OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState, chars.count, &length, &chars
                )
                guard status == noErr, length == 1,
                      let scalar = UnicodeScalar(chars[0]),
                      scalar.value >= 0x20, scalar.value != 0x7F
                else { continue }
                let character = Character(scalar)
                if isShifted {
                    if map.shifted[character] == nil { map.shifted[character] = keyCode }
                } else {
                    if map.plain[character] == nil {
                        map.plain[character] = keyCode
                        map.plainByCode[keyCode] = character
                    }
                }
            }
        }
        return map.plain.isEmpty ? nil : map
    }

    func spec(for character: Character) -> KeySpec? {
        if let code = plain[character] {
            return KeySpec(
                keyCode: code,
                characters: String(character),
                charactersIgnoringModifiers: String(character),
                flags: []
            )
        }
        if let code = shifted[character] {
            let base = plainByCode[code].map(String.init) ?? String(character)
            return KeySpec(
                keyCode: code,
                characters: String(character),
                charactersIgnoringModifiers: base,
                flags: [.shift]
            )
        }
        return nil
    }

    static func spec(for key: DemoScript.SpecialKey) -> KeySpec {
        func make(_ code: Int, _ characters: String, flags: NSEvent.ModifierFlags = []) -> KeySpec {
            KeySpec(
                keyCode: UInt16(code),
                characters: characters,
                charactersIgnoringModifiers: characters,
                flags: flags
            )
        }
        func arrow(_ code: Int, _ functionKey: Int) -> KeySpec {
            let characters = String(UnicodeScalar(functionKey)!)
            return make(code, characters, flags: [.function, .numericPad])
        }
        switch key {
        case .enter: return make(kVK_Return, "\r")
        case .space: return make(kVK_Space, " ")
        case .tab: return make(kVK_Tab, "\t")
        case .esc: return make(kVK_Escape, "\u{1B}")
        case .bs: return make(kVK_Delete, "\u{7F}")
        case .up: return arrow(kVK_UpArrow, NSUpArrowFunctionKey)
        case .down: return arrow(kVK_DownArrow, NSDownArrowFunctionKey)
        case .left: return arrow(kVK_LeftArrow, NSLeftArrowFunctionKey)
        case .right: return arrow(kVK_RightArrow, NSRightArrowFunctionKey)
        case .kana: return make(kVK_JIS_Kana, "")
        case .eisu: return make(kVK_JIS_Eisu, "")
        }
    }
}
