import SwiftUI
import ScreenCaptureKit
import AVFoundation

struct ContentView: View {
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var model: CaptureModel
    @ObservedObject var settings = Settings.shared
    @State private var showAdvanced = false
    @State private var hasScreenPermission = Recorder.hasScreenPermission()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !hasScreenPermission { permissionBanner }
                    if let error = recorder.errorMessage { errorBanner(error) }
                    sourceSection
                    audioSection
                    optionsSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 460, idealWidth: 500, minHeight: 560)
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasScreenPermission = Recorder.hasScreenPermission()
            Task { await model.refresh() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "record.circle")
                .font(.system(size: 26))
                .foregroundStyle(recorder.isRecording ? Color.red : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("OwlCap").font(.headline)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if recorder.isRecording {
                Button {
                    recorder.togglePause()
                } label: {
                    Label(recorder.isPaused ? "Resume" : "Pause",
                          systemImage: recorder.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var statusText: String {
        switch recorder.state {
        case .idle:
            if let last = recorder.lastOutput { return "Saved \(last.lastPathComponent)" }
            return "Ready"
        case .countdown(let n): return "Starting in \(n)…"
        case .recording: return (recorder.isPaused ? "Paused · " : "Recording · ") + Self.timeString(recorder.elapsed)
        case .finishing: return "Finishing up…"
        }
    }

    static func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    // MARK: Banners

    private var permissionBanner: some View {
        banner(icon: "lock.shield", tint: .orange,
               title: "Screen & System Audio Recording is off",
               message: "macOS won't let OwlCap see your screen or hear your Mac until you switch it on.") {
            Button("Open System Settings") {
                Recorder.requestScreenPermission()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
        }
    }

    private func errorBanner(_ text: String) -> some View {
        banner(icon: "exclamationmark.triangle.fill", tint: .red, title: "Something went wrong", message: text) {
            Button("Dismiss") { recorder.errorMessage = nil }
        }
    }

    private func banner<A: View>(icon: String, tint: Color, title: String, message: String,
                                 @ViewBuilder action: () -> A) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint).font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline).bold()
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                action()
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Source

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Record")
            Toggle("Audio only (no video)", isOn: $settings.audioOnly)
                .toggleStyle(.switch)
                .controlSize(.small)

            if !settings.audioOnly {
                Picker("", selection: $settings.source) {
                    ForEach(CaptureSource.allCases) { source in
                        Label(source.label, systemImage: source.symbol).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch settings.source {
                case .display:
                    Picker("Display", selection: $settings.displayID) {
                        ForEach(model.displays, id: \.displayID) { display in
                            Text(Self.displayName(display)).tag(display.displayID)
                        }
                    }
                case .region:
                    HStack {
                        if let region = model.region {
                            Text("\(Int(region.rect.width)) × \(Int(region.rect.height)) points")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No area chosen yet").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(model.region == nil ? "Choose Area…" : "Choose Again…") {
                            Task { await model.chooseRegion() }
                        }
                    }
                    .font(.callout)
                case .window:
                    Picker("Window", selection: $model.selectedWindowID) {
                        ForEach(model.windows, id: \.windowID) { window in
                            Text("\(window.owningApplication?.applicationName ?? "?") — \(window.title ?? "Untitled")")
                                .tag(Optional(window.windowID))
                        }
                    }
                case .app:
                    Picker("Application", selection: $model.selectedAppID) {
                        ForEach(model.apps, id: \.bundleIdentifier) { app in
                            Text(app.applicationName).tag(Optional(app.bundleIdentifier))
                        }
                    }
                }
            }
        }
        .disabled(recorder.isBusy)
    }

    static func displayName(_ display: SCDisplay) -> String {
        let screen = NSScreen.screens.first { $0.displayID == display.displayID }
        let name = screen?.localizedName ?? "Display"
        return "\(name) — \(display.width) × \(display.height)"
    }

    // MARK: Audio

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Sound")

            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $settings.captureSystemAudio) {
                    Label("Computer audio", systemImage: "speaker.wave.2.fill")
                }
                .disabled(recorder.isBusy)
                if settings.captureSystemAudio {
                    LevelMeter(level: recorder.systemLevel, active: recorder.isRecording)
                    Text(systemAudioHint)
                        .font(.caption)
                        .foregroundStyle(recorder.isRecording && !recorder.systemAudioSeen ? .orange : .secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $settings.captureMicrophone) {
                    Label("Microphone", systemImage: "mic.fill")
                }
                .disabled(recorder.isBusy)
                if settings.captureMicrophone {
                    Picker("Input", selection: $settings.microphoneID) {
                        ForEach(model.microphones, id: \.uniqueID) { device in
                            Text(device.localizedName).tag(device.uniqueID)
                        }
                    }
                    .disabled(recorder.isBusy)
                    LevelMeter(level: recorder.micLevel, active: recorder.isRecording)
                }
            }
        }
    }

    private var systemAudioHint: String {
        if recorder.isRecording {
            return recorder.systemAudioSeen
                ? "Computer audio is coming through."
                : "No computer audio yet — play something to check the meter moves."
        }
        return "Captured straight from macOS. No BlackHole or Soundflower needed."
    }

    // MARK: Options

    private var optionsSection: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                if !settings.audioOnly {
                    Toggle("Show the pointer", isOn: $settings.showsCursor)
                    Toggle("Highlight mouse clicks", isOn: $settings.highlightClicks)
                    Text("Click highlighting works when recording a whole screen or an area.")
                        .font(.caption).foregroundStyle(.secondary)

                    Picker("Frame rate", selection: $settings.frameRate) {
                        Text("24 fps").tag(24)
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    Picker("Quality", selection: $settings.quality) {
                        ForEach(VideoQuality.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Codec", selection: $settings.codec) {
                        ForEach(VideoCodecChoice.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("File format", selection: $settings.container) {
                        ForEach(ContainerFormat.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Record at full Retina resolution", isOn: $settings.retinaScale)
                }
                Picker("Countdown", selection: $settings.countdown) {
                    Text("None").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
                Toggle("Reveal in Finder when finished", isOn: $settings.revealInFinder)

                HStack {
                    Text("Save to")
                    Text(settings.saveFolder.lastPathComponent)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Change…") { chooseFolder() }
                }
                .font(.callout)
            }
            .padding(.top, 10)
            .disabled(recorder.isBusy)
        } label: {
            sectionTitle("Options")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.saveFolder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveFolderPath = url.path
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            if let last = recorder.lastOutput, !recorder.isBusy {
                Button {
                    NSWorkspace.shared.open(last)
                } label: {
                    Label("Open last recording", systemImage: "play.rectangle")
                }
                .buttonStyle(.link)
            }
            Spacer()
            Button(action: toggleRecording) {
                Label(recorder.isRecording ? "Stop" : "Record",
                      systemImage: recorder.isRecording ? "stop.fill" : "record.circle.fill")
                    .frame(minWidth: 90)
            }
            .keyboardShortcut(recorder.isRecording ? .escape : .return, modifiers: recorder.isRecording ? [.command, .control] : [])
            .buttonStyle(.borderedProminent)
            .tint(recorder.isRecording ? .red : .accentColor)
            .disabled(recorder.state == .finishing || isCountingDown)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var isCountingDown: Bool {
        if case .countdown = recorder.state { return true }
        return false
    }

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
        } else {
            do {
                let target = try model.target()
                recorder.start(target: target, settings: settings)
            } catch {
                recorder.errorMessage = error.localizedDescription
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption).bold()
            .foregroundStyle(.secondary)
            .kerning(0.6)
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
