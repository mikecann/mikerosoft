import Darwin
import Dispatch

final class AppTerminationLifecycle {
    private let prepareForTermination: () -> Void
    private let requestApplicationTermination: () -> Void
    private var didPrepareForTermination = false

    init(
        prepareForTermination: @escaping () -> Void,
        requestApplicationTermination: @escaping () -> Void
    ) {
        self.prepareForTermination = prepareForTermination
        self.requestApplicationTermination = requestApplicationTermination
    }

    func requestTerminationFromSignal() {
        requestApplicationTermination()
    }

    func applicationWillTerminate() {
        guard !didPrepareForTermination else { return }
        didPrepareForTermination = true
        prepareForTermination()
    }
}

final class TerminationSignalBridge {
    typealias SignalHandlerRegistration = (@escaping () -> Void) -> () -> Void

    private let onSignal: () -> Void
    private let registerSignalHandler: SignalHandlerRegistration
    private var cancelSignalHandler: (() -> Void)?

    init(
        onSignal: @escaping () -> Void,
        registerSignalHandler: @escaping SignalHandlerRegistration = TerminationSignalBridge.registerSIGTERMHandler
    ) {
        self.onSignal = onSignal
        self.registerSignalHandler = registerSignalHandler
    }

    func start() {
        guard cancelSignalHandler == nil else { return }
        cancelSignalHandler = registerSignalHandler { [weak self] in
            self?.onSignal()
        }
    }

    deinit {
        cancelSignalHandler?()
    }

    private static func registerSIGTERMHandler(_ handler: @escaping () -> Void) -> () -> Void {
        _ = Darwin.signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler(handler: handler)
        source.resume()

        return {
            source.cancel()
            _ = Darwin.signal(SIGTERM, SIG_DFL)
        }
    }
}
