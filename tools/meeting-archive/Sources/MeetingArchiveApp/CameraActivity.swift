import CoreMediaIO

/// Whether any process is using a camera. Recording is camera-gated, so while
/// this is false and no session is active, the Accessibility walk (the app's
/// main idle cost) can be skipped. Returns nil when CoreMediaIO cannot answer,
/// in which case callers fall back to polling.
enum CameraActivity {
    static func anyCameraRunning() -> Bool? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &devices) == noErr else { return nil }

        address.mSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
        for device in devices {
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            guard CMIOObjectGetPropertyData(device, &address, 0, nil, runningSize, &runningSize, &running) == noErr else { return nil }
            if running != 0 { return true }
        }
        return false
    }
}
