import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 台本エディタの NSTextView への参照。トークンボタンからカーソル位置に挿入するために使う。
final class ScriptTextViewHolder: ObservableObject {
    weak var textView: NSTextView?

    func insert(_ token: String) {
        guard let textView else { return }
        textView.insertText(token, replacementRange: textView.selectedRange())
        textView.window?.makeFirstResponder(textView)
    }
}

struct ScriptEditorView: View {
    static let clearsBeforePlayKey = "clearsDocumentBeforePlay"

    @ObservedObject private var library = ScriptLibrary.shared
    @ObservedObject private var player = DemoPlayer.shared
    @ObservedObject private var recorder = WindowRecorder.shared
    @StateObject private var holder = ScriptTextViewHolder()

    @AppStorage(EditorWindowTitle.defaultsKey) private var windowTitle: String = ""
    @AppStorage(PlaybackHUD.visibilityDefaultsKey) private var showsHUD: Bool = true
    @AppStorage(ScriptEditorView.clearsBeforePlayKey) private var clearsBeforePlay: Bool = true

    @State private var renamingID: UUID?
    @State private var showsKeycastPanel = false
    @State private var showsRecordingPanel = false
    @State private var showsError = false
    @State private var errorMessage = ""
    @FocusState private var renameFieldFocused: Bool

    private var isPlaying: Bool { player.phase.isActive }
    private var isRecording: Bool { recorder.phase.isActive }
    /// 再生中か録画中。バナー・赤枠・入力の抑止はこちらで判定する。
    private var isBusy: Bool { isPlaying || isRecording }

    var body: some View {
        VStack(spacing: 0) {
            if isBusy {
                playbackBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            controlBar
            Divider()
            tabStrip
            Divider()
            tokenBar
            Divider()
            ScriptTextView(text: scriptBinding, holder: holder, isEditable: !isBusy)
                .opacity(isBusy ? 0.4 : 1)
                .id(library.selectedID)
            Divider()
            referenceFooter
        }
        .animation(.easeInOut(duration: 0.2), value: isBusy)
        .overlay {
            // 再生中は窓全体を赤枠で囲み、どのウィンドウを見ていても状態が分かるようにする
            if isBusy {
                Rectangle()
                    .strokeBorder(Color.red.opacity(0.8), lineWidth: 4)
                    .allowsHitTesting(false)
            }
        }
        .frame(minWidth: 780, minHeight: 560)
        .alert("台本にエラーがあります", isPresented: $showsError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .sheet(item: $recorder.finished) { recording in
            TrimSheet(recording: recording)
        }
    }

    private var scriptBinding: Binding<String> {
        Binding(
            get: { library.currentText },
            set: { library.currentText = $0 }
        )
    }

    // MARK: - 再生中バナー

    private var playbackBanner: some View {
        HStack(spacing: 12) {
            if case .countdown(let remaining) = player.phase {
                Text("\(remaining)")
                    .font(.system(size: 22, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.red)
                    .frame(width: 26)
            } else {
                PulsingDot().frame(width: 26)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(player.phase.isActive ? player.phase.headline : "録画中")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                Text("キーボードとマウスに触れないでください")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if let progress = player.phase.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.red)
                    .frame(maxWidth: 160)
            }

            if case .recording(let startedAt) = recorder.phase {
                recordingClock(since: startedAt)
            }

            Spacer(minLength: 0)

            Button("停止") { stopEverything() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.12))
    }

    /// 録画の経過時間。`● 00:12` の形で出す。
    private func recordingClock(since startedAt: Date) -> some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = Int(max(0, context.date.timeIntervalSince(startedAt)))
            HStack(spacing: 5) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
            }
        }
    }

    // MARK: - 上段: 再生・ウィンドウタイトル・書き出し

    private var controlBar: some View {
        HStack(spacing: 10) {
            Button {
                play()
            } label: {
                Label(isPlaying ? "再生中…" : "再生", systemImage: "play.fill")
            }
            .disabled(isBusy)
            .help("書類ウィンドウを前面に出して再生(ESC で停止)")

            Button {
                recordAndPlay()
            } label: {
                Label("録画して再生", systemImage: "record.circle")
            }
            .disabled(isBusy)
            .help("書類ウィンドウを録画しながら再生し、終わったらトリミング画面を開く")

            Toggle("再生前に本文を消去", isOn: $clearsBeforePlay)
                .disabled(isBusy)
                .help("再生・録画のどちらもこの設定に従う。消去は ⌘Z で元に戻せる")

            Divider().frame(height: 18)

            Text("ウィンドウ名")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("(なし)", text: $windowTitle)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .help("エディタウィンドウのタイトルバーに出す名前。空ならタイトルなし")

            Spacer(minLength: 8)

            Button {
                showsKeycastPanel.toggle()
            } label: {
                Label("キー表示", systemImage: "keyboard")
            }
            .help("押したキーをエディタに重ねて表示する設定")
            .popover(isPresented: $showsKeycastPanel, arrowEdge: .bottom) {
                KeystrokeSettingsPanel()
            }

            Button {
                showsRecordingPanel.toggle()
            } label: {
                Label("録画設定", systemImage: "rectangle.on.rectangle")
            }
            .help("背景・余白・カーソルなど録画の見た目の設定")
            .popover(isPresented: $showsRecordingPanel, arrowEdge: .bottom) {
                RecordingSettingsPanel()
            }

            Button("インポート…") { importScript() }
                .disabled(isBusy)
                .help(".keys ファイルを新しいタブとして読み込む")
            Button("エクスポート…") { exportScript() }
                .disabled(isBusy)
                .help("いま開いている台本を .keys ファイルに書き出す")
        }
        .padding(12)
    }

    private func play() {
        guard let script = parseScript() else { return }
        DemoPlayer.shared.play(script, clearingDocument: clearsBeforePlay)
    }

    /// 録画を先に回してから再生する。録画開始(startCapture)は非同期なので、
    /// 台本の 1 打鍵目より確実に前に始まるよう await してから play する。
    /// 先頭のカウントダウンぶんの余白はトリミングで落とす前提。
    private func recordAndPlay() {
        guard let script = parseScript() else { return }
        Task {
            do {
                try await WindowRecorder.shared.start()
            } catch WindowRecorder.RecorderError.notAuthorized {
                WindowRecorder.shared.presentAuthorizationAlert()
                return
            } catch {
                WindowRecorder.shared.presentAlert("録画を開始できませんでした", error.localizedDescription)
                return
            }
            DemoPlayer.shared.play(script, clearingDocument: clearsBeforePlay) {
                // 完走・停止ボタン・ESC のいずれで終わってもここに来る
                Task { await WindowRecorder.shared.stop() }
            }
        }
    }

    private func stopEverything() {
        if isPlaying {
            // 再生の completion が録画も止める
            DemoPlayer.shared.stop()
        } else if isRecording {
            Task { await WindowRecorder.shared.stop() }
        }
    }

    private func parseScript() -> DemoScript? {
        do {
            return try DemoScript(source: library.currentText)
        } catch {
            errorMessage = error.localizedDescription
            showsError = true
            return nil
        }
    }

    // MARK: - タブ

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(library.tabs) { tab in
                    tabChip(tab)
                }
                Button {
                    let id = library.addTab()
                    renamingID = id
                    renameFieldFocused = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("台本を追加")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .disabled(isBusy)
    }

    @ViewBuilder
    private func tabChip(_ tab: ScriptTab) -> some View {
        let isSelected = tab.id == library.selectedID

        HStack(spacing: 6) {
            if renamingID == tab.id {
                TextField("名前", text: nameBinding(tab))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 96)
                    .focused($renameFieldFocused)
                    .onSubmit { renamingID = nil }
                    .onChange(of: renameFieldFocused) { _, focused in
                        if !focused { renamingID = nil }
                    }
            } else {
                Text(tab.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                if library.tabs.count > 1 {
                    Button {
                        library.remove(tab.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .opacity(isSelected ? 0.6 : 0.25)
                    .help("この台本を削除")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.09),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { startRename(tab) }
        .onTapGesture { library.selectedID = tab.id }
        .contextMenu {
            Button("名前を変更") { startRename(tab) }
            Button("複製") { library.duplicate(tab.id) }
            Divider()
            Button("削除", role: .destructive) { library.remove(tab.id) }
                .disabled(library.tabs.count <= 1)
        }
    }

    private func startRename(_ tab: ScriptTab) {
        library.selectedID = tab.id
        renamingID = tab.id
        renameFieldFocused = true
    }

    private func nameBinding(_ tab: ScriptTab) -> Binding<String> {
        Binding(
            get: { library.tabs.first { $0.id == tab.id }?.name ?? "" },
            set: { library.rename(tab.id, to: $0) }
        )
    }

    // MARK: - トークン挿入ボタン

    private static let tokenRows: [[String]] = [
        ["{enter}", "{space}", "{tab}", "{esc}", "{bs}"],
        ["{up}", "{down}", "{left}", "{right}", "{kana}", "{eisu}", "{wait 0.5}"],
    ]

    private static let tokenHelp: [String: String] = [
        "{enter}": "Return(確定・改行)",
        "{space}": "スペース(変換)",
        "{tab}": "Tab",
        "{esc}": "Escape",
        "{bs}": "Delete(1文字削除)",
        "{up}": "↑", "{down}": "↓(候補選択)", "{left}": "←", "{right}": "→",
        "{kana}": "かなキー(日本語入力へ)",
        "{eisu}": "英数キー(英字入力へ)",
        "{wait 0.5}": "0.5秒待つ(秒数は編集可)",
    ]

    private static let comboSamples = [
        "{shift+enter}", "{cmd+n}", "{cmd+a}", "{cmd+s}", "{cmd+shift+z}",
    ]

    private var tokenBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Self.tokenRows, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { token in
                        tokenButton(token)
                    }
                    if row == Self.tokenRows.last {
                        Menu("組み合わせ") {
                            ForEach(Self.comboSamples, id: \.self) { combo in
                                Button(combo) { holder.insert(combo) }
                            }
                        }
                        .menuStyle(.borderedButton)
                        .fixedSize()
                        .help("修飾キーの組み合わせ例(cmd / shift / opt / ctrl を + でつなぐ)")
                    }
                }
            }
        }
        .disabled(isBusy)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func tokenButton(_ token: String) -> some View {
        Button(token) { holder.insert(token) }
            .buttonStyle(.bordered)
            .font(.system(size: 11, design: .monospaced))
            .help(Self.tokenHelp[token] ?? token)
    }

    // MARK: - 記法リファレンス

    private var referenceFooter: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Text("ディレクティブ(行頭)").bold()
                Text("#lead 3 … 開始までの秒数")
                Text("#interval 100 … キー間隔 ms")
                Text("#jitter 0.35 … 間隔のゆらぎ率")
                Text("#speed 1.0 … 全体速度倍率")
                Text("# … コメント")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("ルール").bold()
                Text("通常の文字は 1 打鍵ずつ送信(変換は IME 任せ)")
                Text("生の改行はキーを送らない。改行は {enter} で明示")
                Text("変換・候補選択({space} {down} 数字)もキーとして書く")
                Text("再生中は AWriter を前面のまま、キーに触れない")
            }
            Spacer()
            VStack(alignment: .leading, spacing: 4) {
                Text("台本はアプリ内に自動保存されます").italic()
                Toggle("再生中の表示を最前面に", isOn: $showsHUD)
                    .toggleStyle(.checkbox)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(12)
    }

    // MARK: - 読み込み・書き出し

    private static var keysContentTypes: [UTType] {
        var types: [UTType] = [.plainText, .text]
        if let keys = UTType(filenameExtension: "keys", conformingTo: .text) {
            types.insert(keys, at: 0)
        }
        return types
    }

    private func importScript() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.keysContentTypes
        panel.message = "台本(.keys)を読み込んで新しいタブにする"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            library.addTab(name: url.deletingPathExtension().lastPathComponent, text: text)
        } catch {
            errorMessage = error.localizedDescription
            showsError = true
        }
    }

    private func exportScript() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = Self.keysContentTypes
        panel.nameFieldStringValue = "\(library.currentName).keys"
        panel.message = "いま開いている台本を書き出す"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try library.currentText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
            showsError = true
        }
    }
}

// MARK: - 台本テキスト編集面(等幅・素のテキスト)

/// 本文側と同じく ⌃↩ では何も起こさない(キーイベント自体は横取りしない)。
final class ScriptNSTextView: NSTextView {
    override func showContextMenuForSelection(_ sender: Any?) {}
    override func insertLineBreak(_ sender: Any?) {}
}

struct ScriptTextView: NSViewRepresentable {
    @Binding var text: String
    let holder: ScriptTextViewHolder
    var isEditable: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ScriptNSTextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 10)

        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        holder.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
        holder.textView = textView
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScriptTextView

        init(_ parent: ScriptTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
