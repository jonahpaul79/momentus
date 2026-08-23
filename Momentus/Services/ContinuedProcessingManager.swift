import BackgroundTasks
import Foundation

/// Runs a user-initiated recording pipeline as an iOS continued-processing task.
/// iOS presents system progress and keeps the workload eligible to run if the
/// person locks the phone or switches apps.
@MainActor
final class ContinuedProcessingManager {
    static let shared = ContinuedProcessingManager()
    static let taskIdentifierPrefix = "jonahpaul.momentus.recording-processing"

    private var pendingJob: Job?
    private var activeJob: Job?
    private var activeOperation: Task<Void, Never>?

    private init() {}

    func run(
        recordingID: UUID,
        title: String,
        onFailure: (@MainActor (Error) -> Void)? = nil,
        operation: @escaping @MainActor (Reporter) async throws -> Void
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard pendingJob == nil, activeJob == nil else {
                    continuation.resume(throwing: ContinuedProcessingError.busy)
                    return
                }

                // Registration is one-shot for the lifetime of this process, so a
                // retry of the same recording needs a fresh task identifier too.
                let taskIdentifier = "\(Self.taskIdentifierPrefix).\(UUID().uuidString.lowercased())"
                let job = Job(
                    recordingID: recordingID,
                    taskIdentifier: taskIdentifier,
                    title: title,
                    onFailure: onFailure,
                    operation: operation,
                    continuation: continuation
                )
                pendingJob = job

                let registered = BGTaskScheduler.shared.register(
                    forTaskWithIdentifier: taskIdentifier,
                    using: nil
                ) { task in
                    guard let task = task as? BGContinuedProcessingTask else {
                        task.setTaskCompleted(success: false)
                        return
                    }
                    Task { @MainActor in
                        ContinuedProcessingManager.shared.handle(
                            task,
                            identifier: taskIdentifier
                        )
                    }
                }

                guard registered else {
                    print("[Continued Processing] registration unavailable; using foreground fallback")
                    pendingJob = nil
                    start(job: job, systemTask: nil)
                    return
                }

                let request = BGContinuedProcessingTaskRequest(
                    identifier: taskIdentifier,
                    title: "Processing \(title)",
                    subtitle: "Preparing your recording"
                )
                // Let iOS wait for processing capacity instead of rejecting a long
                // on-device job immediately on a resource-constrained phone.
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

    func handle(_ task: BGContinuedProcessingTask, identifier: String) {
        guard let job = pendingJob, job.taskIdentifier == identifier else {
            print("[Continued Processing] launched without its pending recording: \(identifier)")
            task.setTaskCompleted(success: false)
            return
        }
        pendingJob = nil
        start(job: job, systemTask: task)
    }

    func cancel(recordingID: UUID) {
        if let pendingJob, pendingJob.recordingID == recordingID {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: pendingJob.taskIdentifier)
            self.pendingJob = nil
            finish(job: pendingJob, systemTask: nil, result: .failure(CancellationError()))
            return
        }
        guard activeJob?.recordingID == recordingID else { return }
        activeOperation?.cancel()
    }

    func isProcessing(recordingID: UUID) -> Bool {
        pendingJob?.recordingID == recordingID || activeJob?.recordingID == recordingID
    }

    private func start(job: Job, systemTask: BGContinuedProcessingTask?) {
        activeJob = job
        let reporter = Reporter(task: systemTask, title: "Processing \(job.title)")
        reporter.update(completed: 0, subtitle: "Preparing your recording")

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
                // Reconcile persisted/app UI state immediately. Model inference may
                // take time to unwind after cancellation, while the system surface
                // marks the continued task failed right away.
                if !job.didReportFailure {
                    job.didReportFailure = true
                    job.onFailure?(CancellationError())
                }
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
            systemTask?.progress.completedUnitCount = systemTask?.progress.totalUnitCount ?? 100
            systemTask?.setTaskCompleted(success: true)
            job.continuation.resume()
        case .failure(let error):
            // Reconcile the app's persisted state before iOS presents a failed
            // continued-processing task to the person.
            if !job.didReportFailure {
                job.didReportFailure = true
                job.onFailure?(error)
            }
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

        func update(completed: Int64, total: Int64 = 100, subtitle: String) {
            guard let task else { return }
            task.progress.totalUnitCount = total
            task.progress.completedUnitCount = min(completed, total)
            task.updateTitle(title, subtitle: subtitle)
        }

        func advance(upTo maximum: Int64, subtitle: String) {
            guard let task else { return }
            task.progress.totalUnitCount = 100
            task.progress.completedUnitCount = min(
                maximum,
                max(task.progress.completedUnitCount + 1, 1)
            )
            task.updateTitle(title, subtitle: subtitle)
        }
    }

    private final class Job {
        let recordingID: UUID
        let taskIdentifier: String
        let title: String
        let onFailure: (@MainActor (Error) -> Void)?
        let operation: @MainActor (Reporter) async throws -> Void
        let continuation: CheckedContinuation<Void, Error>
        var isFinished = false
        var didReportFailure = false

        init(
            recordingID: UUID,
            taskIdentifier: String,
            title: String,
            onFailure: (@MainActor (Error) -> Void)?,
            operation: @escaping @MainActor (Reporter) async throws -> Void,
            continuation: CheckedContinuation<Void, Error>
        ) {
            self.recordingID = recordingID
            self.taskIdentifier = taskIdentifier
            self.title = title
            self.onFailure = onFailure
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
