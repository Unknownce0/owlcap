import AppKit
import SwiftUI
import ScreenCaptureKit

/// The little floating bar, in the spirit of QuickTime's screen-recording controls:
/// pick what to record, set a couple of options, press Record. There is no settings
/// window — everything lives here or in the Options menu.
@MainActor
final class CaptureBar: NSObject {

    private var panel: NSPanel?
    private let settings = Settings.shared
    private weak var controller: AppController?

    init(controller: AppController) {
        self.controller = controller
        super.init()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let content = CaptureBarView(controller: controller)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 62)

        let panel = NSPanel(contentRect: hosting.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        self.panel = panel

        reposition()
        panel.orderFrontRegardless()
    }

    /// Bottom-centre of the active screen, roughly where macOS puts its own capture bar.
    func reposition() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2,
                                     y: screen.frame.minY + 120))
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - Bar contents

private struct CaptureBarView: View {
    weak var controller: AppController?
    @ObservedObject private var settings = Settings.shared
    @State private var hovered: CaptureSource?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                controller?.dismissCapture()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Close")

            separator

            ForEach(CaptureSource.allCases) { source in
                modeButton(source)
            }
            modeButton(nil)   // audio only

            separator

            OptionsMenu()
                .frame(width: 96)

            Button {
                controller?.startRecording()
            } label: {
                Text("Record")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(height: 26)
                    .padding(.horizontal, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(BarBackground())
        .fixedSize()
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.18))
            .frame(width: 1, height: 26)
            .padding(.horizontal, 2)
    }

    /// `nil` means audio-only.
    private func modeButton(_ source: CaptureSource?) -> some View {
        let selected = source == nil ? settings.audioOnly : (!settings.audioOnly && settings.source == source)
        let symbol = source?.symbol ?? "waveform"
        let title = source?.label ?? "Audio Only"
        return Button {
            controller?.choose(source: source)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .frame(width: 34, height: 28)
                .background(selected ? Color.accentColor : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

/// The translucent rounded background macOS uses for this kind of floating control.
private struct BarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 14
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Options

private struct OptionsMenu: View {
    @ObservedObject private var settings = Settings.shared
    @State private var microphones: [AVCaptureDeviceBox] = []

    var body: some View {
        Menu("Options") {
            Section("Save To") {
                folderItem("Movies", .moviesDirectory)
                folderItem("Desktop", .desktopDirectory)
                folderItem("Documents", .documentDirectory)
                Button("Other Location…") { chooseFolder() }
            }

            Section("Timer") {
                check("None", settings.countdown == 0) { settings.countdown = 0 }
                check("5 Seconds", settings.countdown == 5) { settings.countdown = 5 }
                check("10 Seconds", settings.countdown == 10) { settings.countdown = 10 }
            }

            Section("Sound") {
                check("Computer Audio", settings.captureSystemAudio) {
                    settings.captureSystemAudio.toggle()
                }
                check("No Microphone", !settings.captureMicrophone) {
                    settings.captureMicrophone = false
                }
                ForEach(microphones) { mic in
                    check(mic.name, settings.captureMicrophone && settings.microphoneID == mic.id) {
                        settings.captureMicrophone = true
                        settings.microphoneID = mic.id
                    }
                }
            }

            Section("Options") {
                check("Remember Last Selection", settings.rememberSelection) {
                    settings.rememberSelection.toggle()
                }
                check("Show Mouse Pointer", settings.showsCursor) { settings.showsCursor.toggle() }
                check("Show Mouse Clicks", settings.highlightClicks) { settings.highlightClicks.toggle() }
            }

            Menu("Quality") {
                Section("Frame Rate") {
                    ForEach([24, 30, 60], id: \.self) { fps in
                        check("\(fps) fps", settings.frameRate == fps) { settings.frameRate = fps }
                    }
                }
                Section("Quality") {
                    ForEach(VideoQuality.allCases) { q in
                        check(q.label, settings.quality == q) { settings.quality = q }
                    }
                }
                Section("Format") {
                    ForEach(VideoCodecChoice.allCases) { c in
                        check(c.label, settings.codec == c) { settings.codec = c }
                    }
                    ForEach(ContainerFormat.allCases) { f in
                        check(f.label, settings.container == f) { settings.container = f }
                    }
                    check("Full Retina Resolution", settings.retinaScale) { settings.retinaScale.toggle() }
                }
            }

            Section("When Finished") {
                ForEach(AfterRecording.allCases) { option in
                    check(option.label, settings.afterRecording == option) {
                        settings.afterRecording = option
                    }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .onAppear { microphones = AVCaptureDeviceBox.all() }
    }

    private func check(_ title: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // SwiftUI menus have no checkmark API, so mark the active choice inline.
            Text(on ? "✓  \(title)" : "     \(title)")
        }
    }

    private func folderItem(_ name: String, _ directory: FileManager.SearchPathDirectory) -> some View {
        let url = FileManager.default.urls(for: directory, in: .userDomainMask).first
        let active = url.map { settings.saveFolderPath == $0.path } ?? false
        return check(name, active) {
            if let url { settings.saveFolderPath = url.path }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = settings.saveFolder
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveFolderPath = url.path
        }
    }
}

import AVFoundation

struct AVCaptureDeviceBox: Identifiable {
    let id: String
    let name: String
    static func all() -> [AVCaptureDeviceBox] {
        MicrophoneSource.availableDevices().map { AVCaptureDeviceBox(id: $0.uniqueID, name: $0.localizedName) }
    }
}
