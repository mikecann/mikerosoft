import Foundation
import Observation
import TandemCore
import TandemMedia
import TandemRender

/// One export, queued or running.
struct ExportJob: Identifiable, Equatable {
    enum State: Equatable {
        case queued
        case running(progress: Double)
        case done(ExportResult)
        case failed(String)
        case cancelled
    }

    let id = UUID()
    var preset: ExportPreset
    var output: URL
    var state: State = .queued
    var started: Date?

    var isFinished: Bool {
        switch state {
        case .done, .failed, .cancelled: return true
        case .queued, .running: return false
        }
    }
}

/// Runs exports one at a time, in the order they were asked for. The render
/// module shares the hardware encoder with proxy builds through its own
/// lock, so this only has to keep exports from racing each other.
@MainActor
@Observable
final class ExportQueue {
    private(set) var jobs: [ExportJob] = []
    @ObservationIgnored private var contexts: [UUID: RenderContext] = [:]
    @ObservationIgnored private var running: (id: UUID, exporter: Exporter, task: Task<Void, Never>)?
    /// Called when a job finishes, with its final state.
    @ObservationIgnored var onFinish: ((ExportJob) -> Void)?

    var active: ExportJob? { jobs.first { if case .running = $0.state { return true } else { return false } } }
    var waiting: Int { jobs.filter { $0.state == .queued }.count }

    func enqueue(preset: ExportPreset, output: URL, context: RenderContext) {
        let job = ExportJob(preset: preset, output: output)
        jobs.append(job)
        contexts[job.id] = context
        startNext()
    }

    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if running?.id == id {
            running?.exporter.cancel()
            running?.task.cancel()
        }
        if !jobs[index].isFinished { jobs[index].state = .cancelled }
        contexts[id] = nil
    }

    func cancelAll() {
        for job in jobs where !job.isFinished { cancel(job.id) }
    }

    /// Forgets finished jobs.
    func clearFinished() {
        jobs.removeAll { $0.isFinished }
    }

    private func startNext() {
        guard running == nil, let index = jobs.firstIndex(where: { $0.state == .queued }), let context = contexts[jobs[index].id] else { return }
        let job = jobs[index]
        jobs[index].state = .running(progress: 0)
        jobs[index].started = Date()
        try? FileManager.default.createDirectory(at: job.output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let exporter = Exporter(context: context, preset: job.preset, output: job.output)
        let id = job.id
        let report: @Sendable (Double) -> Void = { [weak self] progress in
            guard let self else { return }
            Task { @MainActor in self.update(id, .running(progress: progress)) }
        }
        let task = Task { [weak self] in
            do {
                let result = try await exporter.run(progress: report)
                self?.finish(id, .done(result))
            } catch is CancellationError {
                self?.finish(id, .cancelled)
            } catch {
                let message: String
                if case EditError.notImplemented = error {
                    message = "Export arrives with the render module."
                } else {
                    message = EditorModel.describe(error)
                }
                self?.finish(id, .failed(message))
            }
        }
        running = (id, exporter, task)
    }

    private func update(_ id: UUID, _ state: ExportJob.State) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].isFinished else { return }
        jobs[index].state = state
    }

    private func finish(_ id: UUID, _ state: ExportJob.State) {
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            if jobs[index].state != .cancelled { jobs[index].state = state }
            onFinish?(jobs[index])
        }
        contexts[id] = nil
        if running?.id == id { running = nil }
        startNext()
    }
}
