import Combine
import Foundation

final class RecordingPreferences: ObservableObject {
    private enum Key {
        static let recordingMode = "recordingMode"
        static let openFinderAfterRecording = "openFinderAfterRecording"
        static let selectedEncoderID = "selectedEncoderID"
        static let rateControl = "rateControl"
        static let bitRateMbps = "bitRateMbps"
        static let maximumBitRateMbps = "maximumBitRateMbps"
        static let qualityParameter = "qualityParameter"
    }

    private let defaults: UserDefaults

    @Published var recordingMode: RecordingMode {
        didSet { defaults.set(recordingMode.rawValue, forKey: Key.recordingMode) }
    }

    @Published var openFinderAfterRecording: Bool {
        didSet {
            defaults.set(openFinderAfterRecording, forKey: Key.openFinderAfterRecording)
        }
    }

    @Published var selectedEncoderID: String {
        didSet { defaults.set(selectedEncoderID, forKey: Key.selectedEncoderID) }
    }

    @Published var rateControl: RateControlMode {
        didSet { defaults.set(rateControl.rawValue, forKey: Key.rateControl) }
    }

    @Published var bitRateMbps: Int {
        didSet {
            let clampedValue = min(500, max(1, bitRateMbps))
            if bitRateMbps != clampedValue {
                bitRateMbps = clampedValue
            }
            defaults.set(clampedValue, forKey: Key.bitRateMbps)
        }
    }

    @Published var maximumBitRateMbps: Int {
        didSet {
            let clampedValue = min(500, max(1, maximumBitRateMbps))
            if maximumBitRateMbps != clampedValue {
                maximumBitRateMbps = clampedValue
            }
            defaults.set(clampedValue, forKey: Key.maximumBitRateMbps)
        }
    }

    @Published var qualityParameter: Int {
        didSet {
            let clampedValue = min(51, max(0, qualityParameter))
            if qualityParameter != clampedValue {
                qualityParameter = clampedValue
            }
            defaults.set(clampedValue, forKey: Key.qualityParameter)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recordingMode = defaults.string(forKey: Key.recordingMode)
            .flatMap(RecordingMode.init(rawValue:)) ?? .both
        selectedEncoderID = defaults.string(forKey: Key.selectedEncoderID) ?? ""
        rateControl = defaults.string(forKey: Key.rateControl)
            .flatMap(RateControlMode.init(rawValue:)) ?? .vbr
        bitRateMbps = defaults.object(forKey: Key.bitRateMbps) == nil
            ? 60
            : min(500, max(1, defaults.integer(forKey: Key.bitRateMbps)))
        maximumBitRateMbps = defaults.object(forKey: Key.maximumBitRateMbps) == nil
            ? 80
            : min(500, max(1, defaults.integer(forKey: Key.maximumBitRateMbps)))
        qualityParameter = defaults.object(forKey: Key.qualityParameter) == nil
            ? 20
            : min(51, max(0, defaults.integer(forKey: Key.qualityParameter)))
        if defaults.object(forKey: Key.openFinderAfterRecording) == nil {
            openFinderAfterRecording = true
        } else {
            openFinderAfterRecording = defaults.bool(forKey: Key.openFinderAfterRecording)
        }
    }

    func reconcileEncoderSelection(in encoders: [HardwareVideoEncoder]) {
        guard let encoder = preferredHardwareVideoEncoder(in: encoders, savedID: selectedEncoderID) else {
            selectedEncoderID = ""
            return
        }

        if selectedEncoderID != encoder.id {
            selectedEncoderID = encoder.id
        }
        if let supportedMode = preferredRateControl(
            savedMode: rateControl,
            supportedModes: encoder.supportedRateControls
        ), rateControl != supportedMode {
            rateControl = supportedMode
        }
        if maximumBitRateMbps < bitRateMbps {
            maximumBitRateMbps = bitRateMbps
        }
    }
}
