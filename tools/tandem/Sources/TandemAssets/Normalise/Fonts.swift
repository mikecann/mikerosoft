import CoreText
import Foundation

/// One face in a font file.
public struct FontFace: Codable, Equatable, Sendable {
    public var postScriptName: String
    public var family: String
    public var style: String
}

/// Registering downloaded fonts with Core Text so titles can use them.
///
/// Fonts are registered for this process only, not installed for the user:
/// the app registers the library's fonts (and a project's `assets/fonts`)
/// when it starts or opens a project, and nothing leaks into other apps.
public enum FontInstaller {
    /// The faces in a font file (TTF, OTF, TTC, WOFF or WOFF2).
    public static func faces(in url: URL) -> [FontFace] {
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
        return descriptors.map { descriptor in
            FontFace(
                postScriptName: CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String ?? "",
                family: CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String ?? "",
                style: CTFontDescriptorCopyAttribute(descriptor, kCTFontStyleNameAttribute) as? String ?? ""
            )
        }
    }

    /// Registers fonts for this process. Fonts that are already registered
    /// count as success. Returns the files that failed, with the reason.
    @discardableResult
    public static func register(_ urls: [URL]) async -> [URL: String] {
        guard !urls.isEmpty else { return [:] }
        return await withCheckedContinuation { continuation in
            let collector = FailureCollector()
            CTFontManagerRegisterFontURLs(urls as CFArray, .process, true) { errors, done in
                for case let error as NSError in (errors as? [Any]) ?? [] {
                    // Registering twice isn't a problem for us.
                    if error.code == CTFontManagerError.alreadyRegistered.rawValue { continue }
                    let failed = (error.userInfo[kCTFontManagerErrorFontURLsKey as String] as? [URL]) ?? []
                    for url in failed { collector.add(url, error.localizedDescription) }
                }
                // Resume once, even if Core Text reports done twice.
                if done, collector.finish() { continuation.resume(returning: collector.failures) }
                return true
            }
        }
    }

    /// Collects failures reported on Core Text's callback thread.
    private final class FailureCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URL: String] = [:]
        private var finished = false

        /// True the first time it's called.
        func finish() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if finished { return false }
            finished = true
            return true
        }

        func add(_ url: URL, _ reason: String) {
            lock.lock()
            stored[url] = reason
            lock.unlock()
        }

        var failures: [URL: String] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }
}
