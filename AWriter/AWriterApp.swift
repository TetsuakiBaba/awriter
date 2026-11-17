import SwiftUI

@main
struct AWriterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("AWriter", id: AWriterApp.editorWindowID) {
            EditorView()
        }
        .defaultSize(width: 860, height: 680)
        .commands {
            DemoCommands()
            WindowCommands()
        }

        Window("台本エディタ", id: AWriterApp.scriptWindowID) {
            ScriptEditorView()
        }
        .defaultSize(width: 860, height: 660)
    }

    static let editorWindowID = "editor"
    static let scriptWindowID = "script-editor"
    static let opensScriptEditorAtLaunchKey = "opensScriptEditorAtLaunch"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearanceMode.apply(AppearanceMode.stored)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            ScriptLibrary.shared.saveNow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct DemoCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AWriterApp.opensScriptEditorAtLaunchKey) private var opensScriptEditorAtLaunch = true
    @AppStorage(ScriptEditorView.clearsBeforePlayKey) private var clearsBeforePlay = true
    @ObservedObject private var recorder = WindowRecorder.shared
    @ObservedObject private var player = DemoPlayer.shared

    var body: some Commands {
        CommandMenu("デモ") {
            Button("台本エディタ…") {
                openWindow(id: AWriterApp.scriptWindowID)
            }
            .keyboardShortcut("p", modifiers: [.command, .option])

            Toggle("起動時に台本エディタを開く", isOn: $opensScriptEditorAtLaunch)

            Divider()

            Button("停止") {
                DemoPlayer.shared.stop()
            }
            .keyboardShortcut(".", modifiers: [.command, .option])

            // 止まっているときは手打ちの録画を始め、回っているときは(台本の録画でも)止める
            Button(recorder.phase.isActive ? "録画停止" : "手打ちで録画") {
                WindowRecorder.shared.toggleManual(clearingDocument: clearsBeforePlay)
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(!recorder.phase.isActive && player.phase.isActive)

        }
    }
}

/// ウィンドウを閉じても呼び戻せるようにしておく。
struct WindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowList) {
            Button("エディタ") {
                openWindow(id: AWriterApp.editorWindowID)
            }
            Button("台本エディタ") {
                openWindow(id: AWriterApp.scriptWindowID)
            }
        }
    }
}
