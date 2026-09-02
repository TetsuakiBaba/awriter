import AppKit

/// アプリの外観。撮影時にシステム設定へ左右されないよう、アプリ側で固定できる。
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let defaultsKey = "appearanceMode"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "システム"
        case .light: return "ライト"
        case .dark: return "ダーク"
        }
    }

    private var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    static func apply(_ rawValue: String) {
        let mode = AppearanceMode(rawValue: rawValue) ?? .system
        NSApp.appearance = mode.nsAppearance
    }

    static var stored: String {
        UserDefaults.standard.string(forKey: defaultsKey) ?? AppearanceMode.system.rawValue
    }
}
