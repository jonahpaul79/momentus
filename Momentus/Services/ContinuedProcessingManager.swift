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
        requiresGPU: Bool = false,
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
                if requiresGPU, BGTaskScheduler.supportedResources.contains(.gpu) {
                    request.requiredResources = .gpu
                    print("[Continued Processing] requesting background GPU access")
                }

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
            defer { reporter.stop() }
            do {
                try await job.operation(reporter)
                finish(job: job, systemTask: systemTask, result: .success(()))
            } catch {
                finish(job: job, systemTask: systemTask, result: .failure(error))
            }
        }
        activeOperation = operationTask

        systemTask?.expirationHandler = { [weak self] in
            let progress = systemTask?.progress.fractionCompleted ?? 0
            print(
                "[Continued Processing] system expiration requested for \(job.recordingID) "
                    + "at \(Int(progress * 100))%"
            )
            Task { @MainActor in
                guard let self,
                      !job.isFinished,
                      self.activeJob === job
                else {
                    // iOS can deliver an old continued-task callback after a
                    // subsequent retry has begun. Never let that stale callback
                    // cancel or mark the newer operation as interrupted.
                    print("[Continued Processing] ignored stale expiration for \(job.taskIdentifier)")
                    return
                }
                // Reconcile persisted/app UI state immediately. Model inference may
                // take time to unwind after cancellation, while the system surface
                // marks the continued task failed right away.
                if !job.didReportFailure {
                    job.didReportFailure = true
                    job.onFailure?(CancellationError())
                }
                self.activeOperation?.cancel()
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
        // Detach the system callback before releasing this job. Otherwise a late
        // callback can outlive the job and race with the next user-initiated run.
        systemTask?.expirationHandler = nil
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
        /// Keep the framework task alive until completion. More importantly, keep
        /// its NSProgress moving while an individual model/network request has no
        /// finer-grained callback. iOS can expire continued tasks that look stalled.
        private var task: BGContinuedProcessingTask?
        private let title: String
        private var subtitle = "Preparing your recording"
        private var heartbeatCeiling: Int64 = 100
        private var heartbeatTask: Task<Void, Never>?
        private static let progressScale: Int64 = 10
        private static let totalProgress: Int64 = 100 * progressScale

        fileprivate init(task: BGContinuedProcessingTask?, title: String) {
            self.task = task
            self.title = title
            guard task != nil else { return }
            heartbeatTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled, let self else { return }
                    self.heartbeat()
                }
            }
        }

        func update(completed: Int64, total: Int64 = 100, subtitle: String) {
            guard let task else { return }
            let normalized = total > 0
                ? min(100, max(0, Double(completed) / Double(total) * 100))
                : 0
            let scaled = Int64(normalized * Double(Self.progressScale))
            task.progress.totalUnitCount = Self.totalProgress
            task.progress.completedUnitCount = max(
                task.progress.completedUnitCount,
                min(scaled, Self.totalProgress)
            )
            // Permit heartbeats to advance up to ten percentage points beyond the
            // latest real update without ever claiming the task is complete.
            heartbeatCeiling = max(
                heartbeatCeiling,
                min(Self.totalProgress - 1, scaled + 10 * Self.progressScale)
            )
            self.subtitle = subtitle
            task.updateTitle(title, subtitle: subtitle)
        }

        func advance(upTo maximum: Int64, subtitle: String) {
            guard let task else { return }
            task.progress.totalUnitCount = Self.totalProgress
            heartbeatCeiling = min(Self.totalProgress - 1, maximum * Self.progressScale)
            task.progress.completedUnitCount = min(
                heartbeatCeiling,
                max(task.progress.completedUnitCount + 1, 1)
            )
            self.subtitle = subtitle
            task.updateTitle(title, subtitle: subtitle)
        }

        fileprivate func stop() {
            heartbeatTask?.cancel()
            heartbeatTask = nil
            task = nil
        }

        private func heartbeat() {
            guard let task else { return }
            task.progress.totalUnitCount = Self.totalProgress
            if task.progress.completedUnitCount < heartbeatCeiling {
                task.progress.completedUnitCount += 1
            }
            // Updating both NSProgress and the system surface demonstrates that
            // an awaiting model/network operation is still alive.
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
