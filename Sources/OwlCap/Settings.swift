import Foundation
import AVFoundation
import SwiftUI

enum CaptureSource: String, CaseIterable, Identifiable {
    case display, region
    var id: String { rawValue }
    var label: String {
        switch self {
        case .display: return "Record Entire Screen"
        case .region:  return "Record Selected Portion"
        }
    }
}

enum VideoQuality: String, CaseIterable, Identifiable {
    case high, medium, low
    var id: String { rawValue }
    var label: String {
        switch self {
        case .high:   return "High"
        case .medium: return "Medium"
        case .low:    return "Small file"
        }
    }
    /// Bits per pixel per frame — multiplied by width*height*fps to get a bitrate.
    var bitsPerPixel: Double {
        switch self {
        case .high:   return 0.26
        case .medium: return 0.14
        case .low:    return 0.07
        }
    }
}

enum VideoCodecChoice: String, CaseIterable, Identifiable {
    case hevc, h264
    var id: String { rawValue }
    var label: String { self == .hevc ? "HEVC (H.265)" : "H.264" }
    var avCodec: AVVideoCodecType { self == .hevc ? .hevc : .h264 }
}

/// YouTube only hands uploads its better VP9 encoder at 1440p and above; anything
/// shorter gets H.264 at a much lower bitrate, which is what turns screen text to mush.
/// So this is a floor, not a size: it never shrinks a recording, it only lifts a small
/// one over that line.
enum UploadSize: String, CaseIterable, Identifiable {
    case native, atLeast1440, atLeast2160
    var id: String { rawValue }
    var label: String {
        switch self {
        case .native:       return "Native Size"
        case .atLeast1440:  return "At Least 1440p (YouTube)"
        case .atLeast2160:  return "At Least 2160p"
        }
    }
    var minimumHeight: Int {
        switch self {
        case .native:      return 0
        case .atLeast1440: return 1440
        case .atLeast2160: return 2160
        }
    }
}

enum AfterRecording: String, CaseIterable, Identifiable {
    case openInPlayer, revealInFinder, doNothing
    var id: String { rawValue }
    var label: String {
        switch self {
        case .openInPlayer:   return "Open in QuickTime Player"
        case .revealInFinder: return "Show in Finder"
        case .doNothing:      return "Do Nothing"
        }
    }
}

enum ContainerFormat: String, CaseIterable, Identifiable {
    case mov, mp4
    var id: String { rawValue }
    var label: String { self == .mov ? "QuickTime (.mov)" : "MPEG-4 (.mp4)" }
    var fileType: AVFileType { self == .mov ? .mov : .mp4 }
    var ext: String { rawValue }
}

/// Persisted user preferences. Plain UserDefaults so the app has no dependencies.
final class Settings: ObservableObject {
    static let shared = Settings()

    @Published var source: CaptureSource { didSet { save(source.rawValue, "source") } }
    @Published var displayID: CGDirectDisplayID { didSet { save(Int(displayID), "displayID") } }
    @Published var captureSystemAudio: Bool { didSet { save(captureSystemAudio, "systemAudio") } }
    @Published var captureMicrophone: Bool { didSet { save(captureMicrophone, "micAudio") } }
    @Published var microphoneID: String { didSet { save(microphoneID, "micID") } }
    @Published var showsCursor: Bool { didSet { save(showsCursor, "cursor") } }
    @Published var highlightClicks: Bool { didSet { save(highlightClicks, "clicks") } }
    @Published var countdown: Int { didSet { save(countdown, "countdown") } }
    @Published var frameRate: Int { didSet { save(frameRate, "fps") } }
    @Published var quality: VideoQuality { didSet { save(quality.rawValue, "quality") } }
    @Published var codec: VideoCodecChoice { didSet { save(codec.rawValue, "codec") } }
    @Published var container: ContainerFormat { didSet { save(container.rawValue, "container") } }
    @Published var retinaScale: Bool { didSet { save(retinaScale, "retina") } }
    @Published var revealInFinder: Bool { didSet { save(revealInFinder, "reveal") } }
    @Published var audioOnly: Bool { didSet { save(audioOnly, "audioOnly") } }
    @Published var saveFolderPath: String { didSet { save(saveFolderPath, "saveFolder") } }
    @Published var rememberSelection: Bool { didSet { save(rememberSelection, "rememberSelection") } }
    @Published var afterRecording: AfterRecording { didSet { save(afterRecording.rawValue, "afterRecording") } }
    @Published var uploadSize: UploadSize { didSet { save(uploadSize.rawValue, "uploadSize") } }
    /// The last selected area, remembered between recordings the way QuickTime does.
    /// Stored in global screen points, bottom-left origin.
    @Published var savedRegion: CGRect? { didSet { save(Self.encode(savedRegion), "savedRegion") } }

    private let d = UserDefaults.standard
    /// A transient copy (used by --selftest) reads preferences but never writes them back.
    private var persists = true

    private func save(_ value: Any, _ key: String) {
        guard persists else { return }
        d.set(value, forKey: key)
    }

    /// A throwaway copy of the current preferences that will not be written back.
    static func transient() -> Settings {
        let copy = Settings()
        copy.persists = false
        return copy
    }

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            "systemAudio": true, "micAudio": false, "cursor": true, "clicks": false,
            "countdown": 0, "fps": 60, "retina": true, "reveal": true, "audioOnly": false,
            "rememberSelection": true,
        ])
        source = CaptureSource(rawValue: d.string(forKey: "source") ?? "") ?? .display
        displayID = CGDirectDisplayID(d.integer(forKey: "displayID"))
        captureSystemAudio = d.bool(forKey: "systemAudio")
        captureMicrophone = d.bool(forKey: "micAudio")
        microphoneID = d.string(forKey: "micID") ?? ""
        showsCursor = d.bool(forKey: "cursor")
        highlightClicks = d.bool(forKey: "clicks")
        countdown = d.integer(forKey: "countdown")
        frameRate = max(1, d.integer(forKey: "fps"))
        quality = VideoQuality(rawValue: d.string(forKey: "quality") ?? "") ?? .high
        codec = VideoCodecChoice(rawValue: d.string(forKey: "codec") ?? "") ?? .hevc
        container = ContainerFormat(rawValue: d.string(forKey: "container") ?? "") ?? .mov
        retinaScale = d.bool(forKey: "retina")
        revealInFinder = d.bool(forKey: "reveal")
        audioOnly = d.bool(forKey: "audioOnly")
        rememberSelection = d.bool(forKey: "rememberSelection")
        afterRecording = AfterRecording(rawValue: d.string(forKey: "afterRecording") ?? "") ?? .openInPlayer
        uploadSize = UploadSize(rawValue: d.string(forKey: "uploadSize") ?? "") ?? .atLeast1440
        savedRegion = Self.decode(d.string(forKey: "savedRegion"))
        saveFolderPath = d.string(forKey: "saveFolder")
            ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first?.path
            ?? NSHomeDirectory()
    }

    var saveFolder: URL { URL(fileURLWithPath: saveFolderPath, isDirectory: true) }

    private static func encode(_ rect: CGRect?) -> String {
        guard let rect else { return "" }
        return "\(rect.origin.x),\(rect.origin.y),\(rect.width),\(rect.height)"
    }

    private static func decode(_ text: String?) -> CGRect? {
        guard let parts = text?.split(separator: ",").compactMap({ Double($0) }), parts.count == 4,
              parts[2] > 1, parts[3] > 1 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    func outputURL() -> URL {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        let stem = audioOnly ? "Audio Recording" : "Screen Recording"
        let ext = audioOnly ? "m4a" : container.ext
        var url = saveFolder.appendingPathComponent("\(stem) \(fmt.string(from: Date())).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = saveFolder.appendingPathComponent("\(stem) \(fmt.string(from: Date())) (\(n)).\(ext)")
            n += 1
        }
        return url
    }
}
