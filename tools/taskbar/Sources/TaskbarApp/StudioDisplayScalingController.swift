import AppKit
import CoreGraphics
import Foundation

struct StudioDisplayModeSize: Equatable {
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
}

func studioDisplayScaleTarget(isStudioEnabled: Bool) -> StudioDisplayModeSize {
    if isStudioEnabled {
        // The left-most "Larger Text" choice shown by macOS for PA27JCV.
        return StudioDisplayModeSize(width: 1600, height: 900, pixelWidth: 3200, pixelHeight: 1800)
    }
    // The centre "Default" choice for this 5K 27-inch panel.
    return StudioDisplayModeSize(width: 2560, height: 1440, pixelWidth: 5120, pixelHeight: 2880)
}

func studioDisplayModeIndex(
    matching target: StudioDisplayModeSize,
    in modes: [StudioDisplayModeSize]
) -> Int? {
    modes.firstIndex(of: target)
}

enum StudioDisplayScalingError: LocalizedError {
    case displayUnavailable
    case modeUnavailable(StudioDisplayModeSize)
    case modeChangeFailed(CGError)

    var errorDescription: String? {
        switch self {
        case .displayUnavailable:
            return "PA27JCV is not connected"
        case let .modeUnavailable(mode):
            return "PA27JCV does not expose the expected \(mode.width)x\(mode.height) HiDPI mode"
        case let .modeChangeFailed(error):
            return "macOS could not change PA27JCV scaling (CoreGraphics error \(error.rawValue))"
        }
    }
}

final class StudioDisplayScalingController {
    static let shared = StudioDisplayScalingController()

    private let displayName = "PA27JCV"
    private let queue = DispatchQueue(label: "com.mikerosoft.taskbar.studio-display-scaling", qos: .userInitiated)

    func setStudioEnabled(_ enabled: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        // NSScreen is AppKit state, so resolve the stable display ID on the
        // main queue before doing the CoreGraphics mode change in the worker.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let displayID = self.displayID() else {
                completion(.failure(StudioDisplayScalingError.displayUnavailable))
                return
            }
            self.queue.async {
                let result = Result { try self.setStudioEnabledSynchronously(enabled, displayID: displayID) }
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    private func displayID() -> CGDirectDisplayID? {
        NSScreen.screens.first(where: { $0.localizedName == displayName })?
            .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private func setStudioEnabledSynchronously(
        _ enabled: Bool,
        displayID: CGDirectDisplayID
    ) throws {
        let target = studioDisplayScaleTarget(isStudioEnabled: enabled)
        guard let current = CGDisplayCopyDisplayMode(displayID) else {
            throw StudioDisplayScalingError.displayUnavailable
        }
        if modeSize(current) == target {
            log("PA27JCV scaling is already \(enabled ? "Larger Text" : "Default")")
            return
        }

        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            throw StudioDisplayScalingError.modeUnavailable(target)
        }
        let candidates = modes.filter { modeSize($0) == target && $0.isUsableForDesktopGUI() }
        guard !candidates.isEmpty else {
            throw StudioDisplayScalingError.modeUnavailable(target)
        }

        // Some monitors expose duplicate timing variants. Keep the current
        // refresh rate and low display-mode flags where possible so changing
        // text size does not also alter colour/HDR behaviour.
        let mode = candidates.min { lhs, rhs in
            modePreferenceScore(lhs, current: current) < modePreferenceScore(rhs, current: current)
        }!
        let error = CGDisplaySetDisplayMode(displayID, mode, nil)
        guard error == .success else {
            throw StudioDisplayScalingError.modeChangeFailed(error)
        }
        log("PA27JCV scaling set to \(enabled ? "Larger Text" : "Default") (\(target.width)x\(target.height) HiDPI)")
    }

    private func modeSize(_ mode: CGDisplayMode) -> StudioDisplayModeSize {
        StudioDisplayModeSize(
            width: mode.width,
            height: mode.height,
            pixelWidth: mode.pixelWidth,
            pixelHeight: mode.pixelHeight
        )
    }

    private func modePreferenceScore(_ mode: CGDisplayMode, current: CGDisplayMode) -> Double {
        let refreshDifference = abs(mode.refreshRate - current.refreshRate)
        let lowFlagPenalty = (mode.ioFlags & 0xff) == (current.ioFlags & 0xff) ? 0.0 : 1.0
        return refreshDifference * 10 + lowFlagPenalty
    }
}
