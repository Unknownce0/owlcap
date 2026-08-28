import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// Owns the AVAssetWriter and everything that touches it. Every mutation happens on
/// `queue`, which is also the sample-handler queue we hand to SCStream, so there is
/// exactly one thread writing the movie.
final class CaptureWriter: NSObject, SCStreamOutput, SCStreamDelegate {

    let queue = DispatchQueue(label: "com.unknownce.owlcap.capture")

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput?
    private let audioInput: AVAssetWriterInput?
    let pipeline: AudioPipeline?

    private var sessionStarted = false
    private var paused = false
    private var totalPaused: CMTime = .zero
    private var pauseStart: CMTime?

    /// Called (off the main thread) if ScreenCaptureKit tears the stream down on us.
    var onStreamError: ((Error) -> Void)?

    init(writer: AVAssetWriter,
         videoInput: AVAssetWriterInput?,
         audioInput: AVAssetWriterInput?,
         pipeline: AudioPipeline?) {
        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.pipeline = pipeline
        super.init()
        pipeline?.onBuffer = { [weak self] buffer in self?.appendAudio(buffer) }
    }

    // MARK: - Control

    func setPaused(_ value: Bool) {
        queue.async { self.paused = value }
    }

    func acceptMicSample(_ sample: CMSampleBuffer) {
        queue.async { self.handleMic(sample) }
    }

    func finish() async -> AVAssetWriter.Status {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                continuation.resume()
            }
        }
        if writer.status == .writing {
            await writer.finishWriting()
        }
        return writer.status
    }

    var failureReason: String? { writer.error?.localizedDescription }

    // MARK: - Timeline

    /// Returns the pause-corrected timestamp, or nil when this sample should be dropped.
    private func adjust(_ pts: CMTime) -> CMTime? {
        if paused {
            if pauseStart == nil { pauseStart = pts }
            return nil
        }
        if let started = pauseStart {
            totalPaused = CMTimeAdd(totalPaused, CMTimeSubtract(pts, started))
            pauseStart = nil
        }
        return CMTimeSubtract(pts, totalPaused)
    }

    private func startSessionIfNeeded(at time: CMTime, fromVideo: Bool) -> Bool {
        if sessionStarted { return true }
        // With video present the first video frame defines t=0 so the tracks line up.
        if videoInput != nil && !fromVideo { return false }
        writer.startSession(atSourceTime: time)
        sessionStarted = true
        return true
    }

    // MARK: - Sample handling (always on `queue`)

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer), writer.status == .writing else { return }
        switch type {
        case .screen: handleVideo(sampleBuffer)
        case .audio:  handleSystemAudio(sampleBuffer)
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamError?(error)
    }

    private func handleVideo(_ sample: CMSampleBuffer) {
        guard let videoInput, CMSampleBufferGetImageBuffer(sample) != nil else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw), status != .complete {
            return
        }
        guard let pts = adjust(CMSampleBufferGetPresentationTimeStamp(sample)) else { return }
        guard startSessionIfNeeded(at: pts, fromVideo: true) else { return }
        guard videoInput.isReadyForMoreMediaData else { return }

        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sample),
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var retimed: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                    sampleBuffer: sample,
                                                    sampleTimingEntryCount: 1,
                                                    sampleTimingArray: &timing,
                                                    sampleBufferOut: &retimed) == noErr,
              let retimed else { return }
        videoInput.append(retimed)
    }

    private func handleSystemAudio(_ sample: CMSampleBuffer) {
        guard let pipeline else { return }
        guard let pts = adjust(CMSampleBufferGetPresentationTimeStamp(sample)) else { return }
        guard startSessionIfNeeded(at: pts, fromVideo: false) else { return }
        pipeline.handleSystem(sample, pts: pts)
    }

    private func handleMic(_ sample: CMSampleBuffer) {
        guard let pipeline, writer.status == .writing else { return }
        if pipeline.mixesSystemAudio {
            // System audio drives the clock; this just tops up the mix buffer.
            guard !paused else { return }
            pipeline.handleMic(sample, pts: .zero)
            return
        }
        guard let pts = adjust(CMSampleBufferGetPresentationTimeStamp(sample)) else { return }
        guard startSessionIfNeeded(at: pts, fromVideo: false) else { return }
        pipeline.handleMic(sample, pts: pts)
    }

    private func appendAudio(_ buffer: CMSampleBuffer) {
        guard let audioInput, sessionStarted, writer.status == .writing,
              audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(buffer)
    }
}
