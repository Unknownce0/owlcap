import Foundation
import ScreenCaptureKit
import AppKit
import AVFoundation

/// What the user can pick from, and what they have picked.
@MainActor
final class CaptureModel: ObservableObject {
    @Published var displays: [SCDisplay] = []
    @Published var windows: [SCWindow] = []
    @Published var apps: [SCRunningApplication] = []
    @Published var microphones: [AVCaptureDevice] = []
    @Published var selectedWindowID: CGWindowID?
    @Published var selectedAppID: String?
    @Published var region: (displayID: CGDirectDisplayID, rect: CGRect)?
    @Published var loadFailed: String?

    private let settings = Settings.shared

    func refresh() async {
        microphones = MicrophoneSource.availableDevices()
        do {
            let content = try await Recorder.shareableContent()
            displays = content.displays
            let ownPID = ProcessInfo.processInfo.processIdentifier
            windows = content.windows
                .filter { window in
                    guard let app = window.owningApplication, app.processID != ownPID else { return false }
                    guard window.isOnScreen, window.frame.width > 80, window.frame.height > 80 else { return false }
                    return !(window.title ?? "").isEmpty
                }
                .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
            apps = content.applications
                .filter { $0.processID != ownPID && !$0.applicationName.isEmpty }
                .filter { app in content.windows.contains { $0.owningApplication?.bundleIdentifier == app.bundleIdentifier } }
                .sorted { $0.applicationName.lowercased() < $1.applicationName.lowercased() }
            loadFailed = nil

            if !displays.contains(where: { $0.displayID == settings.displayID }) {
                settings.displayID = displays.first?.displayID ?? 0
            }
            if selectedWindowID == nil { selectedWindowID = windows.first?.windowID }
            if selectedAppID == nil { selectedAppID = apps.first?.bundleIdentifier }
            if settings.microphoneID.isEmpty {
                settings.microphoneID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? ""
            }
        } catch {
            loadFailed = error.localizedDescription
        }
    }

    var selectedDisplay: SCDisplay? {
        displays.first { $0.displayID == settings.displayID } ?? displays.first
    }

    func target() throws -> CaptureTarget {
        if settings.audioOnly { return .audioOnly(selectedDisplay) }
        switch settings.source {
        case .display:
            guard let display = selectedDisplay else { throw RecorderError.noTarget }
            return .display(display)
        case .region:
            guard let region,
                  let display = displays.first(where: { $0.displayID == region.displayID })
            else { throw RecorderError.noTarget }
            return .region(display, region.rect)
        case .window:
            guard let id = selectedWindowID,
                  let window = windows.first(where: { $0.windowID == id })
            else { throw RecorderError.noTarget }
            return .window(window)
        case .app:
            guard let id = selectedAppID,
                  let app = apps.first(where: { $0.bundleIdentifier == id }),
                  let display = selectedDisplay
            else { throw RecorderError.noTarget }
            return .app(app, display)
        }
    }

    func chooseRegion() async {
        let selector = RegionSelector()
        if let picked = await selector.select() {
            region = (picked.0, picked.1)
            settings.displayID = picked.0
            settings.source = .region
        }
    }
}
