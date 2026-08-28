import Foundation
import AVFoundation
import ScreenCaptureKit
import AppKit

/// `OwlCap --selftest [seconds]` — records the main display headlessly and reports what
/// actually landed in the file. This is the quickest way to prove computer audio works.
enum SelfTest {

    static func run(seconds: Double, includeMic: Bool) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        print("OwlCap self-test")
        print("  screen recording permission: \(Recorder.hasScreenPermission() ? "granted" : "NOT granted")")
        if !Recorder.hasScreenPermission() {
            _ = Recorder.requestScreenPermission()
            print("  → Approve OwlCap in System Settings › Privacy & Security › Screen & System Audio Recording, then run this again.")
            exit(2)
        }

        Task { @MainActor in
            let settings = Settings.transient()
            settings.audioOnly = false
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
                print("  recording \(display.width)×\(display.height) for \(seconds)s…")
                recorder.start(target: .display(display), settings: settings)
            } catch {
                print("  failed: \(error.localizedDescription)"); exit(1)
            }

            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            let heardSystem = recorder.systemAudioSeen
            let heardMic = recorder.micAudioSeen
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
                print("  no file was produced"); exit(1)
            }

            let asset = AVURLAsset(url: url)
            let duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
            let video = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0

            print("")
            print("  file:            \(url.path)")
            print("  size:            \(String(format: "%.1f", Double(size ?? 0) / 1_048_576)) MB")
            print("  duration:        \(String(format: "%.2f", duration))s")
            print("  video tracks:    \(video.count)")
            print("  audio tracks:    \(audio.count)")
            print("  computer audio:  \(heardSystem ? "heard sound ✓" : "silent (nothing was playing, or it is not being captured)")")
            if includeMic {
                print("  microphone:      \(heardMic ? "heard sound ✓" : "silent")")
            }
            exit(video.isEmpty || duration < 0.5 ? 1 : 0)
        }

        app.run()
        exit(0)
    }
}
