import Foundation
import AVFoundation

/// Thin wrapper around AVCaptureSession for microphone input.
final class MicrophoneSource: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {

    static func availableDevices() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.microphone]
        types.append(.external)
        return AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                mediaType: .audio,
                                                position: .unspecified).devices
    }

    static func device(withID id: String) -> AVCaptureDevice? {
        if !id.isEmpty, let match = availableDevices().first(where: { $0.uniqueID == id }) { return match }
        return AVCaptureDevice.default(for: .audio)
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "com.unknownce.owlcap.mic")
    private var handler: ((CMSampleBuffer) -> Void)?

    var isRunning: Bool { session.isRunning }

    func start(deviceID: String, handler: @escaping (CMSampleBuffer) -> Void) throws {
        guard let device = Self.device(withID: deviceID) else {
            throw RecorderError.noMicrophone
        }
        self.handler = handler
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for out in session.outputs { session.removeOutput(out) }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw RecorderError.noMicrophone }
        session.addInput(input)
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw RecorderError.noMicrophone }
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
        output.setSampleBufferDelegate(nil, queue: nil)
        handler = nil
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        handler?(sampleBuffer)
    }
}
