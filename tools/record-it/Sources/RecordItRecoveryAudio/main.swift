import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

private enum RecoveryHelperError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(message): message
        }
    }
}

private func argument(named name: String) throws -> String {
    guard
        let index = CommandLine.arguments.firstIndex(of: name),
        CommandLine.arguments.indices.contains(index + 1)
    else {
        throw RecoveryHelperError.message("Missing required argument \(name).")
    }
    return CommandLine.arguments[index + 1]
}

private func audioDeviceIDs() throws -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &size
    ) == noErr else {
        throw RecoveryHelperError.message("Could not enumerate Core Audio devices.")
    }
    var devices = [AudioDeviceID](
        repeating: 0,
        count: Int(size) / MemoryLayout<AudioDeviceID>.size
    )
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &size,
        &devices
    ) == noErr else {
        throw RecoveryHelperError.message("Could not read Core Audio devices.")
    }
    return devices
}

private func stringProperty(
    _ selector: AudioObjectPropertySelector,
    deviceID: AudioDeviceID
) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
        return nil
    }
    return value?.takeUnretainedValue() as String?
}

private func inputChannelCount(deviceID: AudioDeviceID) -> Int {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return 0 }
    let pointer = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { pointer.deallocate() }
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer) == noErr else { return 0 }
    let buffers = UnsafeMutableAudioBufferListPointer(pointer.assumingMemoryBound(to: AudioBufferList.self))
    return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
}

private func selectDevice(uid: String, name: String) throws -> AudioDeviceID {
    let inputDevices = try audioDeviceIDs().filter { inputChannelCount(deviceID: $0) > 0 }
    if let exact = inputDevices.first(where: {
        stringProperty(kAudioDevicePropertyDeviceUID, deviceID: $0) == uid
    }) {
        return exact
    }
    if let named = inputDevices.first(where: {
        stringProperty(kAudioObjectPropertyName, deviceID: $0) == name
    }) {
        return named
    }
    throw RecoveryHelperError.message("Recovery microphone '\(name)' is no longer available.")
}

private final class RecoveryCapture {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private let health: RecoveryCaptureHealth

    init(health: RecoveryCaptureHealth) {
        self.health = health
    }

    func start(deviceID: AudioDeviceID, outputURL: URL) throws {
        guard let audioUnit = engine.inputNode.audioUnit else {
            throw RecoveryHelperError.message("The recovery microphone audio unit could not be created.")
        }
        var mutableDeviceID = deviceID
        let selectStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard selectStatus == noErr else {
            throw RecoveryHelperError.message(
                "The recovery microphone could not be selected (Core Audio \(selectStatus))."
            )
        }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecoveryHelperError.message("The recovery microphone returned an invalid audio format.")
        }
        file = try AVAudioFile(forWriting: outputURL, settings: format.settings)
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            do {
                try self?.file?.write(from: buffer)
                self?.health.record(buffer)
            } catch {
                self?.health.fail("Recovery audio write failed: \(error.localizedDescription)")
            }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
    }
}

private final class RecoveryCaptureHealth: @unchecked Sendable {
    private let lock = NSLock()
    private var lastBufferAt = ProcessInfo.processInfo.systemUptime
    private var digitalSilenceStartedAt: TimeInterval?
    private var failureMessage: String?

    func record(_ buffer: AVAudioPCMBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        var containsNonzeroSample = false
        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let data = audioBuffer.mData else { continue }
            let bytes = data.assumingMemoryBound(to: UInt8.self)
            if (0 ..< Int(audioBuffer.mDataByteSize)).contains(where: { bytes[$0] != 0 }) {
                containsNonzeroSample = true
                break
            }
        }
        lock.withLock {
            lastBufferAt = now
            digitalSilenceStartedAt = containsNonzeroSample
                ? nil
                : (digitalSilenceStartedAt ?? now)
        }
    }

    func fail(_ message: String) {
        lock.withLock { failureMessage = failureMessage ?? message }
    }

    func problem(at now: TimeInterval) -> String? {
        lock.withLock {
            if let failureMessage { return failureMessage }
            if now - lastBufferAt >= 10 {
                return "The independent recovery microphone delivered no audio buffers for 10 seconds."
            }
            if let digitalSilenceStartedAt, now - digitalSilenceStartedAt >= 3 {
                return "The independent recovery microphone delivered digital silence for 3 seconds."
            }
            return nil
        }
    }
}

do {
    let outputURL = URL(fileURLWithPath: try argument(named: "--output"))
    let readyURL = URL(fileURLWithPath: try argument(named: "--ready"))
    defer { try? FileManager.default.removeItem(at: readyURL) }
    let deviceUID = try argument(named: "--device-uid")
    let deviceName = try argument(named: "--device-name")
    let deviceID = try selectDevice(uid: deviceUID, name: deviceName)
    let health = RecoveryCaptureHealth()
    let capture = RecoveryCapture(health: health)

    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    var shouldStop = false
    termination.setEventHandler { shouldStop = true }
    interruption.setEventHandler { shouldStop = true }
    termination.resume()
    interruption.resume()

    try capture.start(deviceID: deviceID, outputURL: outputURL)
    guard FileManager.default.createFile(atPath: readyURL.path, contents: Data()) else {
        throw RecoveryHelperError.message("Could not create the recovery-audio readiness marker.")
    }

    while !shouldStop {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        if let problem = health.problem(at: ProcessInfo.processInfo.systemUptime) {
            throw RecoveryHelperError.message(problem)
        }
    }
    capture.stop()
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
