import AppKit
import SwiftUI

/// QuickTime's New Audio Recording is its own little window rather than the capture
/// bar — a round record button, the running time, and a level meter. This is that.
@MainActor
final class AudioRecorderWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var controller: AppController?

    init(controller: AppController) {
        self.controller = controller
        super.init()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let controller else { return }
        let view = AudioRecorderView(recorder: controller.recorder, controller: controller)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 132)

        let window = NSWindow(contentRect: hosting.frame,
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Audio Recording"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    /// SwiftUI refreshes itself from the recorder; this exists so the controller has one
    /// place to poke when the elapsed time ticks.
    func refresh() {}

    func close() {
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

private struct AudioRecorderView: View {
    @ObservedObject var recorder: Recorder
    weak var controller: AppController?
    @ObservedObject private var settings = Settings.shared
    @State private var microphones: [AVCaptureDeviceBox] = []

    private var recording: Bool { recorder.isRecording }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(AppController.timeString(recorder.elapsed))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)

                Spacer()

                Button {
                    if recording { controller?.stopRecording() } else { controller?.startRecording() }
                } label: {
                    ZStack {
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.25), lineWidth: 2)
                            .frame(width: 54, height: 54)
                        if recording {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.red)
                                .frame(width: 18, height: 18)
                        } else {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 38, height: 38)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(recording ? "Stop" : "Record")

                Spacer()

                Menu {
                    Button(settings.captureSystemAudio ? "✓  Computer Audio" : "     Computer Audio") {
                        settings.captureSystemAudio.toggle()
                    }
                    Divider()
                    Button(!settings.captureMicrophone ? "✓  No Microphone" : "     No Microphone") {
                        settings.captureMicrophone = false
                    }
                    ForEach(microphones) { mic in
                        let on = settings.captureMicrophone && settings.microphoneID == mic.id
                        Button(on ? "✓  \(mic.name)" : "     \(mic.name)") {
                            settings.captureMicrophone = true
                            settings.microphoneID = mic.id
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 60)
                .disabled(recording)
            }

            VStack(spacing: 4) {
                LevelMeter(level: max(recorder.systemLevel, recorder.micLevel), active: recording)
                Text(sourceSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .onAppear { microphones = AVCaptureDeviceBox.all() }
    }

    private var sourceSummary: String {
        switch (settings.captureSystemAudio, settings.captureMicrophone) {
        case (true, true):   return "Computer audio and microphone"
        case (true, false):  return "Computer audio"
        case (false, true):  return "Microphone"
        case (false, false): return "No sound source selected"
        }
    }
}

struct LevelMeter: View {
    let level: Float
    let active: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(level > 0.95 ? Color.red : Color.green)
                    .frame(width: geo.size.width * CGFloat(min(1, sqrt(max(0, level)))))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
        .frame(height: 6)
        .opacity(active ? 1 : 0.35)
    }
}
