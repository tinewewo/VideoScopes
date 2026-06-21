import Foundation

#if HAVE_DECKLINK

// Real capture, backed by the Objective-C++ DLCapture bridge over the DeckLink SDK.
final class DeckLinkSource: VideoSource {
    static func availableDevices() -> [(name: String, make: () -> VideoSource)] {
        let names = DLCapture.deviceNames()
        return names.enumerated().map { (i, n) in
            (name: "DeckLink: \(n)", make: { DeckLinkSource(deviceIndex: i, name: n) })
        }
    }

    let displayName: String
    var onFrame: ((VideoFrame) -> Void)?
    var onFormat: ((String) -> Void)?

    private let capture: DLCapture

    init(deviceIndex: Int, name: String) {
        displayName = name
        capture = DLCapture(deviceIndex: Int32(deviceIndex))
        capture.frameHandler = { [weak self] w, h, rowBytes, isV210, base, len, matrix, range in
            guard let self = self, let base = base else { return }
            let data = Data(bytes: base, count: Int(len))
            let frame = VideoFrame(width: Int(w), height: Int(h), rowBytes: Int(rowBytes),
                                   pixelFormat: isV210 ? .v210 : .uyvy, data: data,
                                   matrix: Int(matrix), range: Int(range))
            self.onFrame?(frame)
        }
        capture.formatHandler = { [weak self] desc in self?.onFormat?(desc) }
    }

    func start() { capture.start() }
    func stop() { capture.stop() }
}

#else

// Stub used when building without the DeckLink SDK / bridge.
final class DeckLinkSource: VideoSource {
    static func availableDevices() -> [(name: String, make: () -> VideoSource)] { [] }
    let displayName = "DeckLink (unavailable)"
    var onFrame: ((VideoFrame) -> Void)?
    var onFormat: ((String) -> Void)?
    func start() {}
    func stop() {}
}

#endif
