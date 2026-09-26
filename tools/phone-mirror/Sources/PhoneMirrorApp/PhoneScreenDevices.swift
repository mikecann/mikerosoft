import AVFoundation
import CoreMediaIO

/// Decides which capture devices are the screens of plugged-in iPhones and iPads.
enum PhoneScreenFilter {
    /// Screen capture devices report the model "iOS Device" and carry muxed video and audio.
    /// Continuity Camera reports the hardware model (e.g. "iPhone11,6") and plain video.
    static func isPhoneScreen(modelID: String, hasMuxedMedia: Bool) -> Bool {
        modelID == "iOS Device" && hasMuxedMedia
    }
}

/// Watches for iPhone and iPad screens connected over USB.
final class PhoneScreenDevices: NSObject {
    /// Called on the main thread with the current phone screens, sorted by name.
    var onChange: (([AVCaptureDevice]) -> Void)?

    private let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.external],
        mediaType: .muxed,
        position: .unspecified
    )
    private var observation: NSKeyValueObservation?

    private(set) var devices: [AVCaptureDevice] = []

    func start() {
        Self.allowScreenCaptureDevices()
        observation = discovery.observe(\.devices, options: [.initial, .new]) { [weak self] session, _ in
            let phones = session.devices
                .filter { PhoneScreenFilter.isPhoneScreen(modelID: $0.modelID, hasMuxedMedia: $0.hasMediaType(.muxed)) }
                .sorted { $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending }
            DispatchQueue.main.async {
                guard let self else { return }
                self.devices = phones
                self.onChange?(phones)
            }
        }
    }

    /// iOS screens stay hidden from AVFoundation until a process opts in. This is the
    /// switch QuickTime flips before offering an iPhone as a movie recording source.
    private static func allowScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &allow
        )
    }
}
