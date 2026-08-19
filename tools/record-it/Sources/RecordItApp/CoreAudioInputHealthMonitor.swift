import CoreAudio
import Foundation

final class CoreAudioInputHealthMonitor: @unchecked Sendable {
    private let deviceUID: String
    private let deviceName: String
    private let queue = DispatchQueue(label: "com.mikerosoft.record-it.core-audio-health")
    private let onFailure: @Sendable (Error) -> Void
    private var deviceID: AudioDeviceID?
    private var initialSampleRate: Float64?
    private var isMonitoring = false

    private lazy var aliveListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        guard let self, let deviceID = self.deviceID else { return }
        var isAlive: UInt32 = 0
        guard self.readProperty(
            kAudioDevicePropertyDeviceIsAlive,
            from: deviceID,
            into: &isAlive
        ) else { return }
        if isAlive == 0 {
            self.report("Core Audio says '\(self.deviceName)' is no longer alive.")
        }
    }

    private lazy var sampleRateListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        guard
            let self,
            let deviceID = self.deviceID,
            let initialSampleRate = self.initialSampleRate
        else { return }
        var currentSampleRate: Float64 = 0
        guard self.readProperty(
            kAudioDevicePropertyNominalSampleRate,
            from: deviceID,
            into: &currentSampleRate
        ) else { return }
        if abs(currentSampleRate - initialSampleRate) >= 0.5 {
            self.report(
                "The microphone sample rate changed during recording "
                    + "from \(Int(initialSampleRate)) Hz to \(Int(currentSampleRate)) Hz."
            )
        }
    }

    init(
        deviceUID: String,
        deviceName: String,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        self.deviceUID = deviceUID
        self.deviceName = deviceName
        self.onFailure = onFailure
    }

    func start() throws {
        guard !isMonitoring else { return }
        guard let deviceID = try coreAudioDeviceID(withUID: deviceUID) else {
            throw RecordItError.message(
                "Core Audio health monitoring could not find microphone '\(deviceName)'."
            )
        }
        self.deviceID = deviceID

        var isAlive: UInt32 = 0
        guard readProperty(kAudioDevicePropertyDeviceIsAlive, from: deviceID, into: &isAlive),
              isAlive != 0
        else {
            throw RecordItError.message("Core Audio says microphone '\(deviceName)' is not alive.")
        }
        var sampleRate: Float64 = 0
        guard readProperty(kAudioDevicePropertyNominalSampleRate, from: deviceID, into: &sampleRate),
              sampleRate > 0
        else {
            throw RecordItError.message(
                "Core Audio could not read the sample rate for microphone '\(deviceName)'."
            )
        }
        initialSampleRate = sampleRate

        var aliveAddress = propertyAddress(kAudioDevicePropertyDeviceIsAlive)
        var sampleRateAddress = propertyAddress(kAudioDevicePropertyNominalSampleRate)
        guard AudioObjectAddPropertyListenerBlock(
            deviceID,
            &aliveAddress,
            queue,
            aliveListener
        ) == noErr else {
            throw RecordItError.message("Could not monitor whether microphone '\(deviceName)' is alive.")
        }
        guard AudioObjectAddPropertyListenerBlock(
            deviceID,
            &sampleRateAddress,
            queue,
            sampleRateListener
        ) == noErr else {
            AudioObjectRemovePropertyListenerBlock(deviceID, &aliveAddress, queue, aliveListener)
            throw RecordItError.message("Could not monitor sample-rate changes for '\(deviceName)'.")
        }
        isMonitoring = true
        RecordingDiagnostics.shared.log(
            "core-audio.monitor device=\(deviceName) sampleRate=\(Int(sampleRate))"
        )
    }

    func stop() {
        guard isMonitoring, let deviceID else { return }
        var aliveAddress = propertyAddress(kAudioDevicePropertyDeviceIsAlive)
        var sampleRateAddress = propertyAddress(kAudioDevicePropertyNominalSampleRate)
        AudioObjectRemovePropertyListenerBlock(deviceID, &aliveAddress, queue, aliveListener)
        AudioObjectRemovePropertyListenerBlock(deviceID, &sampleRateAddress, queue, sampleRateListener)
        isMonitoring = false
        self.deviceID = nil
    }

    private func report(_ message: String) {
        guard isMonitoring else { return }
        onFailure(RecordItError.message(message))
    }

    private func readProperty<T>(
        _ selector: AudioObjectPropertySelector,
        from deviceID: AudioDeviceID,
        into value: inout T
    ) -> Bool {
        var address = propertyAddress(selector)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutableBytes(of: &value) { bytes in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                bytes.baseAddress!
            ) == noErr
        }
    }

    deinit {
        stop()
    }
}

private func propertyAddress(
    _ selector: AudioObjectPropertySelector
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}

private func coreAudioDeviceID(withUID uid: String) throws -> AudioDeviceID? {
    var address = propertyAddress(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
        throw RecordItError.message("Core Audio devices could not be enumerated.")
    }
    var devices = [AudioDeviceID](
        repeating: 0,
        count: Int(size) / MemoryLayout<AudioDeviceID>.size
    )
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else {
        throw RecordItError.message("Core Audio devices could not be read.")
    }
    return devices.first { deviceID in
        var uidAddress = propertyAddress(kAudioDevicePropertyDeviceUID)
        var value: Unmanaged<CFString>?
        var valueSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &uidAddress,
            0,
            nil,
            &valueSize,
            &value
        ) == noErr else { return false }
        return value?.takeUnretainedValue() as String? == uid
    }
}
