import Foundation
import AVFoundation
import ScreenCaptureKit
import AppKit

/// `OwlCap --selftest [seconds]` — records the main display headlessly and reports what
/// actually landed in the file. This is the quickest way to prove computer audio works.
enum SelfTest {

    static func run(seconds: Double, includeMic: Bool, audioOnly: Bool, region: CGRect?) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        print("OwlCap self-test")
        print("  screen recording permission: \(Recorder.hasScreenPermission() ? "granted" : "NOT granted")")
        if !Recorder.hasScreenPermission() {
            _ = Recorder.requestScreenPermission()
            print("  → Approve OwlCap in System Settings › Privacy & Security › Screen & System Audio Recording, then run this again.")
            exit(2)
        }

        if includeMic {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            let names = [AVAuthorizationStatus.notDetermined: "not asked yet — approve the prompt that appears",
                         .restricted: "restricted", .denied: "denied — turn OwlCap on in System Settings › Privacy & Security › Microphone",
                         .authorized: "granted"]
            print("  microphone permission: \(names[status] ?? "unknown")")
        }

        Task { @MainActor in
            let settings = Settings.transient()
            settings.audioOnly = audioOnly
            settings.captureSystemAudio = true
            settings.captureMicrophone = includeMic
            settings.countdown = 0
            settings.revealInFinder = false
            settings.highlightClicks = false

            let recorder = Recorder()
            do {
                let content = try await Recorder.shareableContent()
                guard let display = content.displays.first else {
                    print("  no displays found"); exit(1)
                }
                settings.displayID = display.displayID
                if let region {
                    print("  recording a \(Int(region.width))×\(Int(region.height)) area for \(seconds)s…")
                    recorder.start(target: .region(display, region), settings: settings)
                } else if audioOnly {
                    print("  recording audio only for \(seconds)s…")
                    recorder.start(target: .audioOnly(display), settings: settings)
                } else {
                    print("  recording \(display.width)×\(display.height) for \(seconds)s…")
                    recorder.start(target: .display(display), settings: settings)
                }
            } catch {
                print("  failed: \(error.localizedDescription)"); exit(1)
            }

            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            let heardSystem = recorder.systemAudioSeen
            let heardMic = recorder.micAudioSeen
            let counters = recorder.audioCounters
            recorder.stop()

            // Wait for the writer to close the file.
            for _ in 0..<80 {
                if recorder.lastOutput != nil || recorder.errorMessage != nil { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            if let error = recorder.errorMessage {
                print("  error: \(error)"); exit(1)
            }
            guard let url = recorder.lastOutput else {
                print("  no file was produced — if a permission prompt is waiting, approve it and run this again")
                exit(1)
            }

            let asset = AVURLAsset(url: url)
            let duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
            let video = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))
                .flatMap { $0[.size] as? Int } ?? 0

            print("")
            print("  file:            \(url.path)")
            let bytes = Double(size)
            print("  size:            " + (bytes >= 1_048_576
                ? String(format: "%.1f MB", bytes / 1_048_576)
                : String(format: "%.0f KB", bytes / 1024)))
            print("  duration:        \(String(format: "%.2f", duration))s")
            if let first = video.first, let size = try? await first.load(.naturalSize) {
                print("  video size:      \(Int(size.width)) × \(Int(size.height))")
            }
            print("  video tracks:    \(video.count)")
            print("  audio tracks:    \(audio.count)")
            print("  audio buffers:   \(counters.system) from the system, \(counters.mic) from the mic, \(counters.appended) written, \(counters.dropped) dropped")
            let filePeak = await peakOfAudioTrack(in: asset)
            if let filePeak {
                print("  loudest sample:  \(String(format: "%.3f", filePeak)) \(filePeak > 0.001 ? "— the saved file really has sound in it ✓" : "— the saved audio is silent")")
            }
            print("  computer audio:  \(heardSystem ? "heard sound ✓" : "silent (nothing was playing, or it is not being captured)")")
            if includeMic {
                print("  microphone:      \(heardMic ? "heard sound ✓" : "silent")")
            }
            let ok = duration >= 0.5 && !audio.isEmpty && (audioOnly || !video.isEmpty)
            exit(ok ? 0 : 1)
        }

        app.run()
        exit(0)
    }

    /// Decodes the finished file's audio track and returns its loudest sample, so the
    /// check covers what was actually saved rather than what we think we captured.
    private static func peakOfAudioTrack(in asset: AVAsset) async -> Float? {
        guard let track = (try? await asset.loadTracks(withMediaType: .audio))?.first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var peak: Float = 0
        while let sample = output.copyNextSampleBuffer() {
            try? sample.withAudioBufferList { abl, _ in
                for buffer in abl {
                    guard let data = buffer.mData else { continue }
                    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    let floats = data.bindMemory(to: Float.self, capacity: count)
                    for i in 0..<count { peak = max(peak, abs(floats[i])) }
                }
            }
        }
        return peak
    }
}
