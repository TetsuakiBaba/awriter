import AppKit

/// 収録フォントセット。macOS に同梱されるフォントのみを候補にし、
/// 実行環境に存在するものだけを `available` として提示する。
struct FontOption: Identifiable {
    let id: String
    let name: String
    private let makeFont: (CGFloat) -> NSFont?

    func font(ofSize size: CGFloat) -> NSFont {
        makeFont(size) ?? .systemFont(ofSize: size)
    }

    private var isAvailable: Bool { makeFont(14) != nil }

    static let defaultID = "hiragino-mincho"

    private static let candidates: [FontOption] = [
        FontOption(id: "hiragino-mincho", name: "ヒラギノ明朝") {
            NSFont(name: "HiraMinProN-W3", size: $0)
        },
        FontOption(id: "toppan-mincho", name: "凸版文久明朝") {
            NSFont(name: "ToppanBunkyuMinchoPr6N-Regular", size: $0)
        },
        FontOption(id: "yu-mincho", name: "游明朝体") {
            NSFont(name: "YuMin-Medium", size: $0)
        },
        FontOption(id: "hiragino-sans", name: "ヒラギノ角ゴシック") {
            NSFont(name: "HiraginoSans-W3", size: $0)
        },
        FontOption(id: "toppan-gothic", name: "凸版文久ゴシック") {
            NSFont(name: "ToppanBunkyuGothicPr6N-Regular", size: $0)
        },
        FontOption(id: "hiragino-maru", name: "ヒラギノ丸ゴ") {
            NSFont(name: "HiraMaruProN-W4", size: $0)
        },
        FontOption(id: "tsukushi-maru", name: "筑紫A丸ゴシック") {
            NSFont(name: "TsukuARdGothic-Regular", size: $0)
        },
        FontOption(id: "klee", name: "クレー") {
            NSFont(name: "Klee-Medium", size: $0)
        },
        FontOption(id: "system", name: "システムフォント") {
            .systemFont(ofSize: $0)
        },
        FontOption(id: "new-york", name: "New York") { size in
            NSFont.systemFont(ofSize: size).fontDescriptor
                .withDesign(.serif)
                .flatMap { NSFont(descriptor: $0, size: size) }
        },
    ]

    static let available: [FontOption] = candidates.filter(\.isAvailable)

    static func option(for id: String) -> FontOption {
        available.first { $0.id == id }
            ?? available.first { $0.id == defaultID }
            ?? available[0]
    }
}
