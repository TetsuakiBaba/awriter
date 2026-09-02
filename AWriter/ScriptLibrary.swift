import Foundation

struct ScriptTab: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var text: String
}

/// 台本はアプリ内に保存され、タブで複数のパターンを持てる。
/// ファイルへの書き出しは「エクスポート」であって、保存操作ではない。
@MainActor
final class ScriptLibrary: ObservableObject {
    static let shared = ScriptLibrary()

    @Published var tabs: [ScriptTab] = [] {
        didSet { scheduleSave() }
    }

    @Published var selectedID: UUID = UUID() {
        didSet {
            UserDefaults.standard.set(selectedID.uuidString, forKey: Self.selectionKey)
        }
    }

    private static let libraryKey = "scriptLibrary"
    private static let selectionKey = "scriptLibrarySelectedID"
    private static let legacyTextKey = "demoScriptText"

    private var saveTask: Task<Void, Never>?

    private init() {
        let defaults = UserDefaults.standard
        var loaded: [ScriptTab] = []

        if let data = defaults.data(forKey: Self.libraryKey),
           let decoded = try? JSONDecoder().decode([ScriptTab].self, from: data),
           !decoded.isEmpty {
            loaded = decoded
        } else {
            // タブ導入前に単一の台本を書いていた場合はそれを引き継ぐ
            let legacy = defaults.string(forKey: Self.legacyTextKey) ?? ""
            loaded = legacy.isEmpty
                ? [ScriptTab(name: "サンプル", text: Self.bundledSample)]
                : [ScriptTab(name: "台本 1", text: legacy)]
        }

        tabs = loaded
        if let raw = defaults.string(forKey: Self.selectionKey),
           let id = UUID(uuidString: raw),
           loaded.contains(where: { $0.id == id }) {
            selectedID = id
        } else {
            selectedID = loaded[0].id
        }
    }

    // MARK: - 選択中の台本

    var selectedIndex: Int {
        tabs.firstIndex { $0.id == selectedID } ?? 0
    }

    var currentText: String {
        get { tabs.indices.contains(selectedIndex) ? tabs[selectedIndex].text : "" }
        set {
            guard tabs.indices.contains(selectedIndex) else { return }
            tabs[selectedIndex].text = newValue
        }
    }

    var currentName: String {
        tabs.indices.contains(selectedIndex) ? tabs[selectedIndex].name : ""
    }

    // MARK: - タブ操作

    @discardableResult
    func addTab(name: String = "新規台本", text: String = ScriptLibrary.newTemplate) -> UUID {
        let tab = ScriptTab(name: uniqueName(from: name), text: text)
        tabs.append(tab)
        selectedID = tab.id
        return tab.id
    }

    func duplicate(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        var copy = tabs[index]
        copy.id = UUID()
        copy.name = uniqueName(from: copy.name)
        tabs.insert(copy, at: index + 1)
        selectedID = copy.id
    }

    func remove(_ id: UUID) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selectedID == id {
            selectedID = tabs[min(index, tabs.count - 1)].id
        }
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tabs[index].name = trimmed.isEmpty ? "無題" : trimmed
    }

    private func uniqueName(from base: String) -> String {
        var candidate = base
        var suffix = 2
        while tabs.contains(where: { $0.name == candidate }) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    // MARK: - 永続化

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        guard let data = try? JSONEncoder().encode(tabs) else { return }
        UserDefaults.standard.set(data, forKey: Self.libraryKey)
    }

    // MARK: - 雛形

    static var bundledSample: String {
        if let url = Bundle.main.url(forResource: "sample", withExtension: "keys"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return newTemplate
    }

    static let newTemplate = """
        #lead 3
        #interval 100
        #jitter 0.35

        {kana}{wait 0.5}

        """
}
