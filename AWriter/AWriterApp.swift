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

    var body: some Commands {
        CommandMenu("デモ") {
            Button("台本エディタ…") {
                openWindow(id: AWriterApp.scriptWindowID)
            }
            .keyboardShortcut("p", modifiers: [.command, .option])

            Divider()

            Button("停止") {
                DemoPlayer.shared.stop()
            }
            .keyboardShortcut(".", modifiers: [.command, .option])

            Button("録画停止") {
                Task { await WindowRecorder.shared.stop() }
            }
            .keyboardShortcut("r", modifiers: [.command, .option])

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
