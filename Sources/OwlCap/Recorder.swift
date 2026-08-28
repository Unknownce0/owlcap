import Foundation
import AVFoundation
import ScreenCaptureKit
import AppKit
import Combine

enum RecorderError: LocalizedError {
    case noScreenPermission
    case noMicPermission
    case noMicrophone
    case nothingToRecord
    case noTarget
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noScreenPermission:
            return "OwlCap needs Screen & System Audio Recording permission. Open System Settings › Privacy & Security › Screen & System Audio Recording, switch OwlCap on, then try again."
        case .noMicPermission:
            return "Microphone access was denied. Turn OwlCap on in System Settings › Privacy & Security › Microphone."
        case .noMicrophone:
            return "That microphone could not be opened. Pick a different input."
        case .nothingToRecord:
            return "An audio-only recording needs at least one audio source switched on."
        case .noTarget:
            return "Nothing is selected to record."
        case .writerFailed(let why):
            return "Recording failed: \(why)"
        }
    }
}

enum CaptureTarget {
    case display(SCDisplay)
    case region(SCDisplay, CGRect)      // points, top-left origin, relative to the display
    case window(SCWindow)
    case app(SCRunningApplication, SCDisplay)
    case audioOnly(SCDisplay?)
}

enum RecorderState: Equatable {
    case idle
    case countdown(Int)
    case recording
    case finishing
}

@MainActor
final class Recorder: ObservableObject {

    @Published private(set) var state: RecorderState = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var isPaused = false
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemAudioSeen = false
    @Published private(set) var micAudioSeen = false
    @Published var lastOutput: URL?
    @Published var errorMessage: String?

    var isRecording: Bool { state == .recording }
    /// Diagnostics for `--selftest`: system buffers in, mic buffers in, appended, dropped.
    var audioCounters: (system: Int, mic: Int, appended: Int, dropped: Int) {
        guard let capture else { return (0, 0, 0, 0) }
        return (capture.systemAudioReceived, capture.micReceived, capture.audioAppended, capture.audioDropped)
    }
    var isBusy: Bool { state != .idle }

    private var stream: SCStream?
    private var capture: CaptureWriter?
    private let mic = MicrophoneSource()
    private var clickOverlay: ClickOverlay?
    private var outputURL: URL?
    private var levelTimer: Timer?
    private var elapsedTimer: Timer?
    private var startDate: Date?
    private var pausedAccumulated: TimeInterval = 0
    private var pausedAt: Date?

    // MARK: - Permissions

    nonisolated static func hasScreenPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    nonisolated static func requestScreenPermission() -> Bool { CGRequestScreenCaptureAccess() }

    // MARK: - Start / stop

    func start(target: CaptureTarget, settings: Settings) {
        guard state == .idle else { return }
        errorMessage = nil

        Task { @MainActor in
            guard Self.hasScreenPermission() || Self.requestScreenPermission() else {
                self.errorMessage = RecorderError.noScreenPermission.localizedDescription
                return
            }
            if settings.captureMicrophone, await MicrophoneSource.requestAccess() == false {
                self.errorMessage = RecorderError.noMicPermission.localizedDescription
                return
            }
            if settings.audioOnly && !settings.captureMicrophone && !settings.captureSystemAudio {
                self.errorMessage = RecorderError.nothingToRecord.localizedDescription
                return
            }

            await self.runCountdown(seconds: settings.countdown)

            do {
                try await self.begin(target: target, settings: settings)
            } catch {
                self.state = .idle
                self.errorMessage = error.localizedDescription
                self.teardown()
            }
        }
    }

    private func runCountdown(seconds: Int) async {
        guard seconds > 0 else { return }
        let overlay = CountdownOverlay()
        for n in stride(from: seconds, through: 1, by: -1) {
            state = .countdown(n)
            overlay.show(number: n)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        overlay.close()
    }

    private func begin(target: CaptureTarget, settings: Settings) async throws {
        let url = settings.outputURL()
        outputURL = url
        try? FileManager.default.removeItem(at: url)

        let audioOnly = settings.audioOnly
        let fileType: AVFileType = audioOnly ? .m4a : settings.container.fileType
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)

        // Click highlighting draws into a transparent overlay window that the capture picks up.
        var overlayWindowID: CGWindowID?
        if settings.highlightClicks && !audioOnly && Self.supportsClickHighlight(target) {
            let overlay = ClickOverlay()
            overlay.start()
            clickOverlay = overlay
            overlayWindowID = overlay.windowID
        }

        let filter = try await Self.makeFilter(for: target, keepingWindow: overlayWindowID)
        let config = SCStreamConfiguration()
        config.capturesAudio = settings.captureSystemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.queueDepth = 6

        if audioOnly {
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        } else {
            let scale = settings.retinaScale ? Self.scaleFactor(for: target) : 1
            var size = Self.pointSize(for: target)
            if case .region(_, let rect) = target {
                size = rect.size
                config.sourceRect = rect
                config.scalesToFit = false
            }
            let w = Int((size.width * scale).rounded()) & ~1
            let h = Int((size.height * scale).rounded()) & ~1
            config.width = max(2, w)
            config.height = max(2, h)
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
            config.showsCursor = settings.showsCursor
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
        }

        // Video track
        var videoInput: AVAssetWriterInput?
        if !audioOnly {
            let w = config.width, h = config.height
            let bitrate = Int(Double(w * h * settings.frameRate) * settings.quality.bitsPerPixel)
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: max(1_000_000, min(bitrate, 220_000_000)),
                AVVideoExpectedSourceFrameRateKey: settings.frameRate,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ]
            if settings.codec == .h264 {
                compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: settings.codec.avCodec,
                AVVideoWidthKey: w,
                AVVideoHeightKey: h,
                AVVideoCompressionPropertiesKey: compression,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecorderError.writerFailed("the video encoder refused these settings") }
            writer.add(input)
            videoInput = input
        }

        // Audio track
        var audioInput: AVAssetWriterInput?
        var pipeline: AudioPipeline?
        if settings.captureSystemAudio || settings.captureMicrophone {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256_000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecorderError.writerFailed("the audio encoder refused these settings") }
            writer.add(input)
            audioInput = input
            pipeline = AudioPipeline(systemAudio: settings.captureSystemAudio,
                                     microphone: settings.captureMicrophone)
        }

        guard writer.startWriting() else {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "could not open the output file")
        }

        let capture = CaptureWriter(writer: writer, videoInput: videoInput,
                                    audioInput: audioInput, pipeline: pipeline)
        capture.onStreamError = { [weak self] error in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                self.errorMessage = "Capture stopped: \(error.localizedDescription)"
                self.stop()
            }
        }
        self.capture = capture

        let stream = SCStream(filter: filter, configuration: config, delegate: capture)
        self.stream = stream
        if !audioOnly {
            try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: capture.queue)
        }
        if settings.captureSystemAudio {
            try stream.addStreamOutput(capture, type: .audio, sampleHandlerQueue: capture.queue)
        }
        try await stream.startCapture()

        if settings.captureMicrophone {
            try mic.start(deviceID: settings.microphoneID) { [weak capture] sample in
                capture?.acceptMicSample(sample)
            }
        }

        pausedAccumulated = 0
        pausedAt = nil
        isPaused = false
        startDate = Date()
        elapsed = 0
        systemAudioSeen = false
        micAudioSeen = false
        state = .recording
        startTimers()
    }

    func stop() {
        guard state == .recording else { return }
        state = .finishing
        stopTimers()
        let capture = self.capture
        let stream = self.stream
        Task { @MainActor in
            if let stream { try? await stream.stopCapture() }
            self.mic.stop()
            self.clickOverlay?.stop()
            self.clickOverlay = nil
            if let capture {
                let status = await capture.finish()
                if status == .failed {
                    self.errorMessage = RecorderError
                        .writerFailed(capture.failureReason ?? "unknown error").localizedDescription
                } else if let url = self.outputURL,
                          FileManager.default.fileExists(atPath: url.path) {
                    self.lastOutput = url
                    switch Settings.shared.afterRecording {
                    case .openInPlayer:   NSWorkspace.shared.open(url)
                    case .revealInFinder: NSWorkspace.shared.activateFileViewerSelecting([url])
                    case .doNothing:      break
                    }
                }
            }
            self.stream = nil
            self.teardown()
            self.state = .idle
        }
    }

    func togglePause() {
        guard state == .recording else { return }
        isPaused.toggle()
        capture?.setPaused(isPaused)
        if isPaused {
            pausedAt = Date()
        } else if let pausedAt {
            pausedAccumulated += Date().timeIntervalSince(pausedAt)
            self.pausedAt = nil
        }
    }

    private func teardown() {
        capture = nil
        systemLevel = 0
        micLevel = 0
        isPaused = false
        clickOverlay?.stop()
        clickOverlay = nil
        mic.stop()
        stopTimers()
    }

    // MARK: - Timers

    private func startTimers() {
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startDate else { return }
                var paused = self.pausedAccumulated
                if let p = self.pausedAt { paused += Date().timeIntervalSince(p) }
                self.elapsed = max(0, Date().timeIntervalSince(start) - paused)
            }
        }
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let pipe = self.capture?.pipeline else { return }
                self.systemLevel = pipe.systemPeak
                self.micLevel = pipe.micPeak
                self.systemAudioSeen = pipe.sawSystemAudio
                self.micAudioSeen = pipe.sawMicAudio
            }
        }
    }

    private func stopTimers() {
        elapsedTimer?.invalidate(); elapsedTimer = nil
        levelTimer?.invalidate(); levelTimer = nil
    }

    // MARK: - Filters and geometry

    static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    static func supportsClickHighlight(_ target: CaptureTarget) -> Bool {
        switch target {
        case .display, .region: return true
        default: return false
        }
    }

    private static func makeFilter(for target: CaptureTarget,
                                   keepingWindow keep: CGWindowID?) async throws -> SCContentFilter {
        let content = try await shareableContent()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownWindows = content.windows.filter {
            $0.owningApplication?.processID == ownPID && $0.windowID != (keep ?? 0)
        }

        switch target {
        case .display(let display), .region(let display, _):
            return SCContentFilter(display: display, excludingWindows: ownWindows)
        case .window(let window):
            return SCContentFilter(desktopIndependentWindow: window)
        case .app(let app, let display):
            return SCContentFilter(display: display, including: [app], exceptingWindows: [])
        case .audioOnly(let display):
            if let display {
                return SCContentFilter(display: display, excludingWindows: ownWindows)
            }
            guard let first = content.displays.first else { throw RecorderError.noTarget }
            return SCContentFilter(display: first, excludingWindows: ownWindows)
        }
    }

    private static func pointSize(for target: CaptureTarget) -> CGSize {
        switch target {
        case .display(let d), .app(_, let d), .audioOnly(.some(let d)):
            return CGSize(width: d.width, height: d.height)
        case .region(_, let rect):
            return rect.size
        case .window(let w):
            return w.frame.size
        case .audioOnly(nil):
            return CGSize(width: 2, height: 2)
        }
    }

    static func scaleFactor(for target: CaptureTarget) -> CGFloat {
        var displayID: CGDirectDisplayID?
        switch target {
        case .display(let d), .region(let d, _), .app(_, let d), .audioOnly(.some(let d)):
            displayID = d.displayID
        case .window(let w):
            displayID = NSScreen.screens.first { $0.frame.intersects(w.frame) }?.displayID
        case .audioOnly(nil):
            displayID = nil
        }
        guard let displayID,
              let screen = NSScreen.screens.first(where: { $0.displayID == displayID })
        else { return NSScreen.main?.backingScaleFactor ?? 2 }
        return screen.backingScaleFactor
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
