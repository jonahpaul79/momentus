import Foundation

// MARK: - Recording

/// The root object. Contains everything about one recording session.
///
/// **Ownership / relationships:**
/// - `Recording` owns one optional `Transcript` and one optional `MeetingSummary`.
/// - Both are populated asynchronously by the processing pipeline in `RecordViewModel`.
/// - `Recording` is stored in `RecordingsStore` and serialized via `Codable`.
///
/// **State machine:** `processingState` drives what UI is shown.
/// `idle` → `savingAudio` → `transcribing` → `summarizing` → `preparingNotes` → `completed`
/// A recording is never shown in the Notes list in `.idle` state.
struct Recording: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    let startedAt: Date
    var endedAt: Date?
    var mode: RecordingMode
    var micSource: MicSource
    var audioFileID: String?
    var processingState: ProcessingState
    var transcript: Transcript?
    var summary: MeetingSummary?
    var isFavorite: Bool
    var markers: [TimeInterval]
    var hasActionItems: Bool { (summary?.actionItems.isEmpty == false) }
    var actionItemCount: Int { summary?.actionItems.count ?? 0 }
    var duration: TimeInterval {
        guard let end = endedAt else { return 0 }
        return end.timeIntervalSince(startedAt)
    }
    var shortSummary: String? { summary?.executiveSummary }
    var confidenceScore: Float? { transcript?.averageConfidence }
    var isLowConfidence: Bool { (confidenceScore ?? 1.0) < 0.75 }

    init(
        id: UUID = UUID(),
        title: String = "New Recording",
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        mode: RecordingMode = .onDevice,
        micSource: MicSource = .iPhone,
        audioFileID: String? = nil,
        processingState: ProcessingState = .idle,
        transcript: Transcript? = nil,
        summary: MeetingSummary? = nil,
        isFavorite: Bool = false,
        markers: [TimeInterval] = []
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.mode = mode
        self.micSource = micSource
        self.audioFileID = audioFileID
        self.processingState = processingState
        self.transcript = transcript
        self.summary = summary
        self.isFavorite = isFavorite
        self.markers = markers
    }
}

// MARK: - Transcript

struct Transcript: Identifiable, Codable, Equatable {
    let id: UUID
    let recordingId: UUID
    var segments: [TranscriptSegment]
    var speakers: [Speaker]
    var language: String
    var provider: String
    var createdAt: Date

    var averageConfidence: Float {
        guard !segments.isEmpty else { return 1.0 }
        return segments.map(\.confidence).reduce(0, +) / Float(segments.count)
    }

    var fullText: String {
        segments.map(\.text).joined(separator: " ")
    }
}

// MARK: - TranscriptSegment

struct TranscriptSegment: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    var speakerId: UUID?
    var confidence: Float
    var isLowConfidence: Bool { confidence < 0.72 }
    var isEdited: Bool = false
}

// MARK: - Speaker

struct Speaker: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var isNameInferred: Bool
    var colorHex: String

    static let unknown = Speaker(id: UUID(), name: "Unknown", isNameInferred: false, colorHex: "#8B8FA8")
}

// MARK: - MeetingSummary

struct MeetingSummary: Identifiable, Codable, Equatable {
    let id: UUID
    let recordingId: UUID
    var suggestedTitle: String?
    var executiveSummary: String
    var decisions: [Decision]
    var actionItems: [ActionItem]
    var openQuestions: [OpenQuestion]
    var risks: [Risk]
    var followUpDraft: String
    var provider: String
    var createdAt: Date
    var confidenceNotes: [String]
}

// MARK: - ActionItem

struct ActionItem: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var owner: String?
    var isOwnerInferred: Bool
    var dueDate: Date?
    var isDueDateInferred: Bool
    var isCompleted: Bool
    var confidence: Float
    var priority: Priority

    enum Priority: String, Codable, CaseIterable, Equatable {
        case high, medium, low

        var displayName: String { rawValue.capitalized }
        var sortOrder: Int {
            switch self { case .high: return 0; case .medium: return 1; case .low: return 2 }
        }
    }
}

// MARK: - Decision

struct Decision: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var context: String?
    var confidence: Float
}

// MARK: - OpenQuestion

struct OpenQuestion: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var owner: String?
    var priority: Priority

    enum Priority: String, Codable, CaseIterable, Equatable {
        case critical, high, medium, low
        var displayName: String { rawValue.capitalized }
    }
}

// MARK: - Risk

struct Risk: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var description: String
    var severity: Severity

    enum Severity: String, Codable, CaseIterable, Equatable {
        case critical, high, medium, low
        var displayName: String { rawValue.capitalized }
    }
}

// MARK: - Enums

enum ProcessingState: String, Codable, CaseIterable, Equatable {
    case idle
    case savingAudio
    case transcribing
    case summarizing
    case preparingNotes
    case completed
    case failed

    var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .savingAudio: return "Saving audio"
        case .transcribing: return "Transcribing"
        case .summarizing: return "Summarizing"
        case .preparingNotes: return "Preparing notes"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    var stepIndex: Int {
        switch self {
        case .idle: return -1
        case .savingAudio: return 0
        case .transcribing: return 1
        case .summarizing: return 2
        case .preparingNotes: return 3
        case .completed: return 4
        case .failed: return -1
        }
    }
}

enum RecordingMode: String, Codable, CaseIterable, Equatable, Identifiable {
    case onDevice
    case bestQuality
    case hybrid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .onDevice: return "Private"
        case .bestQuality: return "Best Quality"
        case .hybrid: return "Hybrid"
        }
    }

    var shortName: String {
        switch self {
        case .onDevice: return "Private"
        case .bestQuality: return "Quality"
        case .hybrid: return "Hybrid"
        }
    }

    var description: String {
        switch self {
        case .onDevice: return "Transcription and summary stay on-device."
        case .bestQuality: return "Cloud transcription for maximum accuracy."
        case .hybrid: return "On-device transcript, cloud summary."
        }
    }

    var privacyLabel: String {
        switch self {
        case .onDevice: return "On-device only"
        case .bestQuality: return "Sent to provider"
        case .hybrid: return "Transcript local, summary cloud"
        }
    }

    var icon: String {
        switch self {
        case .onDevice: return "lock.shield.fill"
        case .bestQuality: return "sparkles"
        case .hybrid: return "arrow.triangle.2.circlepath"
        }
    }

    var usesCloud: Bool {
        switch self {
        case .onDevice: return false
        case .bestQuality, .hybrid: return true
        }
    }
}

enum MicSource: String, Codable, CaseIterable, Equatable, Identifiable {
    case iPhone
    case watch

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .iPhone: return "iPhone"
        case .watch: return "Apple Watch"
        }
    }

    var shortName: String {
        switch self {
        case .iPhone: return "iPhone mic"
        case .watch: return "Watch mic"
        }
    }

    var icon: String {
        switch self {
        case .iPhone: return "iphone"
        case .watch: return "applewatch"
        }
    }
}

enum RecordingFilter: String, CaseIterable, Equatable, Identifiable {
    case all
    case thisWeek
    case withActionItems
    case lowConfidence
    case favorites

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "All"
        case .thisWeek: return "This week"
        case .withActionItems: return "Action items"
        case .lowConfidence: return "Low confidence"
        case .favorites: return "Favorites"
        }
    }
}

// MARK: - Calendar

struct CalendarMeeting: Identifiable {
    let id: UUID
    let title: String
    let startDate: Date
    let endDate: Date
    let attendees: [String]
    var isHappeningNow: Bool {
        let now = Date()
        return startDate <= now && endDate >= now
    }
    var isStartingSoon: Bool {
        let fiveMin = Date().addingTimeInterval(5 * 60)
        return startDate <= fiveMin && startDate > Date()
    }
}
