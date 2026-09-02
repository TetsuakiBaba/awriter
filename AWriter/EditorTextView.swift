import SwiftUI
import AppKit

/// 本文カラムをウィンドウ中央に固定幅で組む NSTextView。
final class AWTextView: NSTextView {
    static let maxColumnWidth: CGFloat = 720
    static let verticalInset: CGFloat = 56

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
    }

    /// 台本再生の合成キーも実際の打鍵もここを通るので、キー表示は一箇所で拾える。
    override func keyDown(with event: NSEvent) {
        KeystrokeOverlay.shared.report(event)
        super.keyDown(with: event)
        // 変換中は super のあとに挿入点が動くので、確定した位置を次のループで拾う
        DispatchQueue.main.async { [weak self] in self?.publishCaretRect() }
    }

    /// 入力メソッドは変換中の文字列に自前の色を付けて渡してくる。
    /// `markedTextAttributes` より優先されるので、ここで無彩色に差し替える。
    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        super.setMarkedText(
            Self.monochrome(string),
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
    }

    private static func monochrome(_ string: Any) -> Any {
        // 属性なしの素の文字列なら markedTextAttributes がそのまま効く
        guard let attributed = string as? NSAttributedString, attributed.length > 0 else {
            return string
        }

        let result = NSMutableAttributedString(attributedString: attributed)
        let whole = NSRange(location: 0, length: result.length)
        result.beginEditing()
        result.enumerateAttributes(in: whole, options: []) { attributes, range, _ in
            if attributes[.underlineStyle] != nil {
                result.addAttribute(.underlineColor, value: NSColor.compositionUnderline, range: range)
            }
            if attributes[.backgroundColor] != nil {
                result.addAttribute(.backgroundColor, value: NSColor.compositionFill, range: range)
            }
        }
        result.endEditing()
        return result
    }

    // ⌃↩ を AWriter では何も起こさないキーにする。
    //
    // キーイベント自体は横取りせず、割り当てられている二つのアクションだけを
    // 空にしている。グローバルショートカットの類はアプリに配送される前段で
    // 処理されるため、この方式なら他アプリの ⌃↩ に一切干渉しない。

    /// macOS 標準の「選択範囲の文脈メニューを表示」。右クリックのメニューは従来どおり出る。
    override func showContextMenuForSelection(_ sender: Any?) {}

    /// StandardKeyBinding で ⌃↩ に割り当てられている行区切り(U+2028)の挿入。
    override func insertLineBreak(_ sender: Any?) {}

    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        publishCaretRect()
    }

    /// 挿入点の矩形をスクロールビュー内の座標に直して発信する。
    private func publishCaretRect() {
        guard KeystrokeOverlay.followsCaret,
              let window,
              let clipView = enclosingScrollView?.contentView
        else { return }

        let caret = NSRange(location: selectedRange().location, length: 0)
        let onScreen = firstRect(forCharacterRange: caret, actualRange: nil)
        guard onScreen.origin.x.isFinite, onScreen.origin.y.isFinite else { return }

        let inWindow = window.convertFromScreen(onScreen)
        var inClip = clipView.convert(inWindow, from: nil)
        if inClip.height < 1 { inClip.size.height = layoutHeightGuess }

        KeystrokeOverlay.shared.caretRect = inClip
    }

    /// 空行などで挿入点の高さが取れないときの控え。
    private var layoutHeightGuess: CGFloat {
        (font?.pointSize ?? 16) * 1.7
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateInsets()
        window?.makeFirstResponder(self)
    }

    private func updateInsets() {
        let horizontal = max(32, (bounds.width - Self.maxColumnWidth) / 2)
        let inset = NSSize(width: horizontal, height: Self.verticalInset)
        if abs(textContainerInset.width - inset.width) > 0.5
            || abs(textContainerInset.height - inset.height) > 0.5 {
            textContainerInset = inset
        }
    }
}

struct EditorTextView: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let textColor: NSColor

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = AWTextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.usesFontPanel = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = .paper
        // カーソル・変換中の下線・クローズの地はすべて無彩色にする
        // (既定ではアプリのアクセントカラーが出てしまう)
        textView.insertionPointColor = .labelColor
        textView.markedTextAttributes = [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: NSColor.compositionUnderline,
            .backgroundColor: NSColor.compositionFill,
        ]
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor.compositionFill,
        ]

        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .paper

        textView.string = text
        context.coordinator.apply(font: font, color: textColor, to: textView, force: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? AWTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.apply(font: font, color: textColor, to: textView, force: false)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditorTextView
        private var appliedFont: NSFont?
        private var appliedColor: NSColor?

        init(_ parent: EditorTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func apply(font: NSFont, color: NSColor, to textView: NSTextView, force: Bool) {
            if !force, appliedFont == font, appliedColor == color { return }
            appliedFont = font
            appliedColor = color

            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = 1.7
            style.paragraphSpacing = font.pointSize * 0.4

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: style,
            ]
            textView.defaultParagraphStyle = style
            textView.typingAttributes = attributes
            if let storage = textView.textStorage {
                storage.beginEditing()
                storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
                storage.endEditing()
            }
            textView.font = font
            textView.textColor = color
        }
    }
}
