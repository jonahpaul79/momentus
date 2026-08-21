import BackgroundTasks
import Foundation

/// Runs a user-initiated recording pipeline as an iOS continued-processing task.
/// iOS presents system progress and keeps the workload eligible to run if the
/// person locks the phone or switches apps.
@MainActor
final class ContinuedProcessingManager {
    static let shared = ContinuedProcessingManager()
    static let taskIdentifier = "jonahpaul.momentus.recording-processing.active"

    private var pendingJob: Job?
    private var activeJob: Job?
    private var activeOperation: Task<Void, Never>?

    private init() {}

    func run(
        recordingID: UUID,
        title: String,
        operation: @escaping @MainActor (Reporter) async throws -> Void
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard pendingJob == nil, activeJob == nil else {
                    continuation.resume(throwing: ContinuedProcessingError.busy)
                    return
                }

                let job = Job(
                    recordingID: recordingID,
                    title: title,
                    operation: operation,
                    continuation: continuation
                )
                pendingJob = job

                let request = BGContinuedProcessingTaskRequest(
                    identifier: Self.taskIdentifier,
                    title: "Processing \(title)",
                    subtitle: "Preparing your recording"
                )
                request.strategy = .queue

                do {
                    try BGTaskScheduler.shared.submit(request)
                    print("[Continued Processing] submitted \(recordingID)")
                } catch {
                    // A simulator or a device with background processing disabled can
                    // reject submission. Continue in the foreground rather than fail.
                    print("[Continued Processing] submission unavailable; using foreground fallback: \(error)")
                    pendingJob = nil
                    start(job: job, systemTask: nil)
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.cancel(recordingID: recordingID)
            }
        }
    }

    func handle(_ task: BGContinuedProcessingTask) {
        guard let job = pendingJob else {
            print("[Continued Processing] launched without a pending recording")
            task.setTaskCompleted(success: false)
            return
        }
        pendingJob = nil
        start(job: job, systemTask: task)
    }

    func cancel(recordingID: UUID) {
        if let pendingJob, pendingJob.recordingID == recordingID {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
            self.pendingJob = nil
            finish(job: pendingJob, systemTask: nil, result: .failure(CancellationError()))
            return
        }
        guard activeJob?.recordingID == recordingID else { return }
        activeOperation?.cancel()
    }

    private func start(job: Job, systemTask: BGContinuedProcessingTask?) {
        activeJob = job
        let reporter = Reporter(task: systemTask, title: "Processing \(job.title)")
        reporter.update(completed: 0, total: 4, subtitle: "Preparing your recording")

        let operationTask = Task { @MainActor in
            do {
                try await job.operation(reporter)
                finish(job: job, systemTask: systemTask, result: .success(()))
            } catch {
                finish(job: job, systemTask: systemTask, result: .failure(error))
            }
        }
        activeOperation = operationTask

        systemTask?.expirationHandler = { [weak self] in
            print("[Continued Processing] system expiration requested for \(job.recordingID)")
            Task { @MainActor in
                self?.activeOperation?.cancel()
            }
        }
    }

    private func finish(
        job: Job,
        systemTask: BGContinuedProcessingTask?,
        result: Result<Void, Error>
    ) {
        guard !job.isFinished else { return }
        job.isFinished = true
        activeOperation = nil
        if activeJob === job { activeJob = nil }

        switch result {
        case .success:
            systemTask?.progress.completedUnitCount = systemTask?.progress.totalUnitCount ?? 4
            systemTask?.setTaskCompleted(success: true)
            job.continuation.resume()
        case .failure(let error):
            systemTask?.setTaskCompleted(success: false)
            job.continuation.resume(throwing: error)
        }
    }

    @MainActor
    final class Reporter {
        private weak var task: BGContinuedProcessingTask?
        private let title: String

        fileprivate init(task: BGContinuedProcessingTask?, title: String) {
            self.task = task
            self.title = title
        }

        func update(completed: Int64, total: Int64 = 4, subtitle: String) {
            guard let task else { return }
            task.progress.totalUnitCount = total
            task.progress.completedUnitCount = min(completed, total)
            task.updateTitle(title, subtitle: subtitle)
        }
    }

    private final class Job {
        let recordingID: UUID
        let title: String
        let operation: @MainActor (Reporter) async throws -> Void
        let continuation: CheckedContinuation<Void, Error>
        var isFinished = false

        init(
            recordingID: UUID,
            title: String,
            operation: @escaping @MainActor (Reporter) async throws -> Void,
            continuation: CheckedContinuation<Void, Error>
        ) {
            self.recordingID = recordingID
            self.title = title
            self.operation = operation
            self.continuation = continuation
        }
    }
}

enum ContinuedProcessingError: LocalizedError {
    case busy

    var errorDescription: String? {
        "Another recording is already being processed."
    }
}
