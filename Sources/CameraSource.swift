import AVFoundation
import Foundation

// Any AVFoundation video device (built-in FaceTime camera, USB / virtual
// webcams, Continuity Camera). Frames are requested as BGRA and fed through
// the shared Metal pipeline like every other source.
final class CameraSource: NSObject, VideoSource, AVCaptureVideoDataOutputSampleBufferDelegate {

    static func availableDevices() -> [(name: String, make: () -> VideoSource)] {
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]
        let ds = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
        return ds.devices.map { dev in
            (name: "Camera: \(dev.localizedName)", make: { CameraSource(device: dev) })
        }
    }

    let displayName: String
    var onFrame: ((VideoFrame) -> Void)?
    var onFormat: ((String) -> Void)?

    private let device: AVCaptureDevice
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let videoQueue = DispatchQueue(label: "camera.video")
    private var reported = false

    init(device: AVCaptureDevice) {
        self.device = device
        self.displayName = device.localizedName
        super.init()
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQueue.async { [weak self] in self?.configureAndStart() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self = self else { return }
                if granted { self.sessionQueue.async { self.configureAndStart() } }
                else { self.emit("Camera · access denied — allow in System Settings › Privacy › Camera") }
            }
        default:
            emit("Camera · access denied — allow in System Settings › Privacy › Camera")
        }
    }

    private func configureAndStart() {
        session.beginConfiguration()
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            emit("Camera · unable to open \(displayName)")
            return
        }
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        session.startRunning()
        emit("Camera · starting … \(displayName)")
    }

    func stop() {
        sessionQueue.async { [weak self] in
            if let s = self?.session, s.isRunning { s.stopRunning() }
        }
    }

    deinit {
        if session.isRunning { session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let rb = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let frame = VideoFrame(width: w, height: h, rowBytes: rb, pixelFormat: .bgra,
                               data: Data(bytes: base, count: rb * h), matrix: 1, range: 1)
        if !reported { reported = true; emit("Camera · \(w)×\(h) · BGRA · \(displayName)") }
        onFrame?(frame)
    }

    private func emit(_ s: String) {
        DispatchQueue.main.async { [weak self] in self?.onFormat?(s) }
    }
}
