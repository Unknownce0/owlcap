import Foundation
import AVFoundation
import CoreMedia

/// Everything audio: takes whatever ScreenCaptureKit and the microphone hand us,
/// normalises it to one format, mixes the two together when both are on, and hands
/// finished CMSampleBuffers back to the recorder.
///
/// System audio is the clock when it is enabled — microphone frames are buffered and
/// summed into each system chunk. When only the mic is on, the mic drives the clock.
final class AudioPipeline {

    static let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 48_000,
                                            channels: 2,
                                            interleaved: true)!

    /// Called with mixed audio ready to be written.
    var onBuffer: ((CMSampleBuffer) -> Void)?

    private(set) var systemPeak: Float = 0
    private(set) var micPeak: Float = 0
    /// True once we have actually seen non-silent system audio — this is what tells the
    /// user their computer audio is really being picked up.
    private(set) var sawSystemAudio = false
    private(set) var sawMicAudio = false

    let mixesSystemAudio: Bool
    let mixesMicrophone: Bool
    private var mixSystem: Bool { mixesSystemAudio }
    private var mixMic: Bool { mixesMicrophone }

    private let lock = NSLock()
    private var micRing: [Float] = []           // interleaved stereo
    private let maxRingFrames = 48_000 / 2       // 0.5 s of slack before we drop

    private var converters: [String: AVAudioConverter] = [:]

    init(systemAudio: Bool, microphone: Bool) {
        self.mixesSystemAudio = systemAudio
        self.mixesMicrophone = microphone
    }

    // MARK: - Inputs

    func handleSystem(_ sample: CMSampleBuffer, pts: CMTime) {
        guard mixSystem, let pcm = Self.convert(sample, to: Self.outputFormat, cache: &converters) else { return }
        let frames = Int(pcm.frameLength)
        guard frames > 0, let data = pcm.floatChannelData?[0] else { return }

        if mixMic {
            let mic = takeMic(frames: frames)
            if !mic.isEmpty {
                for i in 0..<(frames * 2) {
                    data[i] = max(-1, min(1, data[i] + mic[i]))
                }
            }
        }
        systemPeak = Self.peak(data, count: frames * 2)
        if systemPeak > 0.0005 { sawSystemAudio = true }

        if let out = Self.makeSampleBuffer(from: pcm, pts: pts) {
            onBuffer?(out)
        }
    }

    func handleMic(_ sample: CMSampleBuffer, pts: CMTime) {
        guard mixMic, let pcm = Self.convert(sample, to: Self.outputFormat, cache: &converters) else { return }
        let frames = Int(pcm.frameLength)
        guard frames > 0, let data = pcm.floatChannelData?[0] else { return }

        micPeak = Self.peak(data, count: frames * 2)
        if micPeak > 0.0005 { sawMicAudio = true }

        if mixSystem {
            // Buffer it; the system clock will pull it back out.
            lock.lock()
            micRing.append(contentsOf: UnsafeBufferPointer(start: data, count: frames * 2))
            if micRing.count > maxRingFrames * 2 {
                micRing.removeFirst(micRing.count - maxRingFrames * 2)
            }
            lock.unlock()
        } else {
            // Mic is the only source, so it drives the timeline directly.
            if let out = Self.makeSampleBuffer(from: pcm, pts: pts) {
                onBuffer?(out)
            }
        }
    }

    private func takeMic(frames: Int) -> [Float] {
        let wanted = frames * 2
        lock.lock()
        defer { lock.unlock() }
        guard !micRing.isEmpty else { return [] }
        if micRing.count >= wanted {
            let out = Array(micRing[0..<wanted])
            micRing.removeFirst(wanted)
            return out
        }
        // Underrun: use what we have and pad with silence rather than glitching.
        var out = micRing
        micRing.removeAll(keepingCapacity: true)
        out.append(contentsOf: [Float](repeating: 0, count: wanted - out.count))
        return out
    }

    func reset() {
        lock.lock(); micRing.removeAll(); lock.unlock()
        systemPeak = 0; micPeak = 0
    }

    // MARK: - Helpers

    private static func peak(_ p: UnsafePointer<Float>, count: Int) -> Float {
        var m: Float = 0
        for i in 0..<count { m = max(m, abs(p[i])) }
        return m
    }

    /// Convert an incoming CMSampleBuffer of PCM into our canonical format, into memory
    /// we own. The sample's own buffers are only valid inside `withAudioBufferList`, so
    /// every copy and conversion has to finish before that closure returns.
    static func convert(_ sample: CMSampleBuffer,
                        to format: AVAudioFormat,
                        cache: inout [String: AVAudioConverter]) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
        else { return nil }

        var layoutSize = 0
        let layoutPtr = CMAudioFormatDescriptionGetChannelLayout(desc, sizeOut: &layoutSize)
        let inFormat: AVAudioFormat?
        if let layoutPtr, layoutSize > 0 {
            inFormat = AVAudioFormat(streamDescription: asbd,
                                     channelLayout: AVAudioChannelLayout(layout: layoutPtr))
        } else {
            inFormat = AVAudioFormat(streamDescription: asbd)
        }
        guard let inFormat else { return nil }

        let inFrames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard inFrames > 0 else { return nil }

        let key = "\(inFormat.sampleRate)-\(inFormat.channelCount)-\(inFormat.commonFormat.rawValue)-\(inFormat.isInterleaved)"
        var converter: AVAudioConverter?
        if inFormat != format {
            if let cached = cache[key] {
                converter = cached
            } else {
                guard let made = AVAudioConverter(from: inFormat, to: format) else { return nil }
                cache[key] = made
                converter = made
            }
        }

        var output: AVAudioPCMBuffer?
        try? sample.withAudioBufferList { abl, _ in
            guard let source = AVAudioPCMBuffer(pcmFormat: inFormat,
                                                bufferListNoCopy: abl.unsafePointer) else { return }
            guard let converter else {
                // Same format already — just take our own copy of the samples.
                guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: source.frameLength),
                      let src = source.floatChannelData, let dst = copy.floatChannelData
                else { return }
                copy.frameLength = source.frameLength
                let perBuffer = Int(source.frameLength) * (format.isInterleaved ? Int(format.channelCount) : 1)
                for channel in 0..<(format.isInterleaved ? 1 : Int(format.channelCount)) {
                    dst[channel].update(from: src[channel], count: perBuffer)
                }
                output = copy
                return
            }

            let ratio = format.sampleRate / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 1024
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, outStatus in
                if supplied {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return source
            }
            if error == nil && converted.frameLength > 0 { output = converted }
        }
        return output
    }

    /// Wrap PCM back up as a CMSampleBuffer so AVAssetWriter will take it.
    static func makeSampleBuffer(from pcm: AVAudioPCMBuffer, pts: CMTime) -> CMSampleBuffer? {
        var asbd = pcm.format.streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                             asbd: &asbd,
                                             layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil,
                                             formatDescriptionOut: &formatDescription) == noErr,
              let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                   dataBuffer: nil, dataReady: false,
                                   makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: formatDescription,
                                   sampleCount: CMItemCount(pcm.frameLength),
                                   sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer else { return nil }

        guard CMSampleBufferSetDataBufferFromAudioBufferList(
                sampleBuffer,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                bufferList: pcm.audioBufferList) == noErr else { return nil }

        return sampleBuffer
    }
}
