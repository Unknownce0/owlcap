import SwiftUI
import AppKit

@main
struct Entry {
    static func main() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--selftest") {
            let seconds = args.count > index + 1 ? (Double(args[index + 1]) ?? 6) : 6
            var region: CGRect?
            if let r = args.firstIndex(of: "--region"), args.count > r + 1 {
                let parts = args[r + 1].split(separator: ",").compactMap { Double($0) }
                if parts.count == 4 {
                    region = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
                }
            }
            SelfTest.run(seconds: seconds,
                         includeMic: args.contains("--mic"),
                         audioOnly: args.contains("--audio-only"),
                         region: region)
        }
        OwlCapApp.main()
    }
}

struct OwlCapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var recorder = Recorder()
    @StateObject private var model = CaptureModel()
    @ObservedObject private var settings = Settings.shared

    var body: some Scene {
        Window("OwlCap", id: "main") {
            ContentView()
                .environmentObject(recorder)
                .environmentObject(model)
                .onAppear {
                    delegate.recorder = recorder
                    StopHotkey.shared.install()
                    StopHotkey.shared.onPress = { recorder.stop() }
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Screen Recording") {
                    settings.audioOnly = false
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("n", modifiers: [.command])
                Button("New Audio Recording") {
                    settings.audioOnly = true
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Stop Recording") { recorder.stop() }
                    .keyboardShortcut(.escape, modifiers: [.command, .control])
                    .disabled(!recorder.isRecording)
            }
        }

        MenuBarExtra {
            MenuBarContent(recorder: recorder, model: model)
        } label: {
            if recorder.isRecording {
                Label(ContentView.timeString(recorder.elapsed), systemImage: "record.circle.fill")
            } else {
                Image(systemName: "record.circle")
            }
        }
    }
}

struct MenuBarContent: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var model: CaptureModel
    @ObservedObject private var settings = Settings.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if recorder.isRecording {
            Text(recorder.isPaused ? "Paused — \(ContentView.timeString(recorder.elapsed))"
                                   : "Recording — \(ContentView.timeString(recorder.elapsed))")
            Button("Stop Recording  ⌘⌃⎋") { recorder.stop() }
            Button(recorder.isPaused ? "Resume" : "Pause") { recorder.togglePause() }
        } else {
            Button("Start Recording") {
                do {
                    recorder.start(target: try model.target(), settings: settings)
                } catch {
                    recorder.errorMessage = error.localizedDescription
                    activate()
                }
            }
            Button("Record an Area…") {
                Task {
                    await model.chooseRegion()
                    if model.region != nil, let target = try? model.target() {
                        recorder.start(target: target, settings: settings)
                    }
                }
            }
        }
        Divider()
        Button("Open OwlCap") { activate() }
        if let last = recorder.lastOutput {
            Button("Show Last Recording") {
                NSWorkspace.shared.activateFileViewerSelecting([last])
            }
        }
        Divider()
        Button("Quit OwlCap") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func activate() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var recorder: Recorder?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recorder, recorder.isRecording else { return .terminateNow }
        recorder.stop()
        // Give the writer a moment to close the file cleanly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
