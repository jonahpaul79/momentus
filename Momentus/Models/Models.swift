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
/// `idle` → `savingAudio` → `uploading` → `transcribing` → `summarizing` → `preparingNotes` → `completed`
/// A recording is never shown in the Notes list in `.idle` state.
struct Recording: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    /// `true` once a person explicitly renames the recording. Optional so
    /// recordings saved by older app versions continue to decode.
    var titleWasEditedByUser: Bool?
    let startedAt: Date
    var endedAt: Date?
    var mode: RecordingMode
    var micSource: MicSource
    var audioFileID: String?
    /// Tombstone propagated through CloudKit so another device cannot re-upload
    /// audio that the retention policy already removed.
    var rawAudioDeletedAt: Date?
    var processingState: ProcessingState
    /// The last processing failure, persisted so Notes can explain and retry it.
    var processingError: String?
    /// Stage-specific status such as "Uploading 18.0 MB of 92.4 MB (19%)".
    var processingDetail: String?
    /// Fractional progress for stages that can report it, currently audio upload.
    var processingProgress: Double?
    /// Remote transcription job checkpoint. Keeping this lets an interrupted cloud
    /// pipeline resume polling without uploading a large recording a second time.
    var transcriptionJobID: String?
    /// Used to reject legacy or stale jobs that would otherwise be polled indefinitely.
    var transcriptionJobCreatedAt: Date?
    var transcript: Transcript?
    var summary: MeetingSummary?
    var isFavorite: Bool
    var markers: [TimeInterval]
    var calendarAttendees: [String]?
    var hasActionItems: Bool { (summary?.actionItems.isEmpty == false) }
    var actionItemCount: Int { summary?.actionItems.count ?? 0 }
    var duration: TimeInterval {
        guard let end = endedAt else { return 0 }
        return end.timeIntervalSince(startedAt)
    }
    var shortSummary: String? { summary?.executiveSummary }
    var hasUsableTranscriptionCheckpoint: Bool {
        guard transcriptionJobID != nil, let createdAt = transcriptionJobCreatedAt else { return false }
        return Date().timeIntervalSince(createdAt) < 24 * 60 * 60
    }

    init(
        id: UUID = UUID(),
        title: String = "New Recording",
        titleWasEditedByUser: Bool? = nil,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        mode: RecordingMode = .onDevice,
        micSource: MicSource = .iPhone,
        audioFileID: String? = nil,
        rawAudioDeletedAt: Date? = nil,
        processingState: ProcessingState = .idle,
        processingError: String? = nil,
        processingDetail: String? = nil,
        processingProgress: Double? = nil,
        transcriptionJobID: String? = nil,
        transcriptionJobCreatedAt: Date? = nil,
        transcript: Transcript? = nil,
        summary: MeetingSummary? = nil,
        isFavorite: Bool = false,
        markers: [TimeInterval] = [],
        calendarAttendees: [String]? = nil
    ) {
        self.id = id
        self.title = title
        self.titleWasEditedByUser = titleWasEditedByUser
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.mode = mode
        self.micSource = micSource
        self.audioFileID = audioFileID
        self.rawAudioDeletedAt = rawAudioDeletedAt
        self.processingState = processingState
        self.processingError = processingError
        self.processingDetail = processingDetail
        self.processingProgress = processingProgress
        self.transcriptionJobID = transcriptionJobID
        self.transcriptionJobCreatedAt = transcriptionJobCreatedAt
        self.transcript = transcript
        self.summary = summary
        self.isFavorite = isFavorite
        self.markers = markers
        self.calendarAttendees = calendarAttendees
    }
}

extension Recording {
    /// Confirms speaker identities and keeps every generated note section in sync.
    /// The provider's original label is retained so reassignment can also repair
    /// legacy summaries that still contain placeholders such as "Speaker A".
    mutating func assignSpeakerNames(_ assignments: [UUID: String]) {
        guard var transcript else { return }
        var replacements: [String: String] = [:]

        for (speakerID, proposedName) in assignments {
            let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  let index = transcript.speakers.firstIndex(where: { $0.id == speakerID })
            else { continue }

            let currentName = transcript.speakers[index].name
            let originalNameKey = "momentus_original_speaker_\(speakerID.uuidString)"
            let originalName = transcript.providerData[originalNameKey] ?? currentName

            if transcript.providerData[originalNameKey] == nil {
                transcript.providerData[originalNameKey] = currentName
            }
            replacements[currentName] = name
            replacements[originalName] = name
            transcript.speakers[index].name = name
            transcript.speakers[index].isNameInferred = false
        }

        self.transcript = transcript
        summary?.renameSpeakerReferences(replacements)
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
    /// Provider-specific metadata (e.g. ["assemblyai_transcript_id": "abc123"]).
    /// Used by paired summary services (e.g. AssemblyAISummaryService reads the ID to call LeMUR).
    var providerData: [String: String] = [:]
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

// MARK: - TranscriptTextSanitizer

enum TranscriptTextSanitizer {
    static func cleaned(_ rawText: String) -> String? {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        text = text.replacingOccurrences(
            of: #"<\|[^|>]*\|>"#,
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\[(?:BLANK_AUDIO|SILENCE|NO[_ ]?SPEECH|INAUDIBLE|UNINTELLIGIBLE|MUSIC|NOISE|BACKGROUND NOISE)\]"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)

        return text.isEmpty ? nil : text
    }
}

// MARK: - Speaker

struct Speaker: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var isNameInferred: Bool
    var colorHex: String

    static let unknown = Speaker(id: UUID(), name: "Unknown", isNameInferred: true, colorHex: "#8B8FA8")

    /// Provider-generated labels such as "Speaker A" are placeholders, even in
    /// recordings created before providers correctly marked them as inferred.
    var requiresIdentification: Bool {
        if isNameInferred { return true }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare("Unknown") == .orderedSame { return true }
        return trimmed.range(
            of: #"^speaker(?:\s+[a-z0-9]+)?$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}

// MARK: - MeetingSummary

struct MeetingSummary: Identifiable, Codable, Equatable {
    let id: UUID
    let recordingId: UUID
    var suggestedTitle: String?
    var executiveSummary: String
    var markedMoments: [MarkedMoment]
    var decisions: [Decision]
    var actionItems: [ActionItem]
    var openQuestions: [OpenQuestion]
    var risks: [Risk]
    var followUpDraft: String
    var provider: String
    var createdAt: Date
    var confidenceNotes: [String]

    init(
        id: UUID = UUID(),
        recordingId: UUID,
        suggestedTitle: String? = nil,
        executiveSummary: String,
        markedMoments: [MarkedMoment] = [],
        decisions: [Decision] = [],
        actionItems: [ActionItem] = [],
        openQuestions: [OpenQuestion] = [],
        risks: [Risk] = [],
        followUpDraft: String,
        provider: String,
        createdAt: Date = Date(),
        confidenceNotes: [String] = []
    ) {
        self.id = id
        self.recordingId = recordingId
        self.suggestedTitle = suggestedTitle
        self.executiveSummary = executiveSummary
        self.markedMoments = markedMoments
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.risks = risks
        self.followUpDraft = followUpDraft
        self.provider = provider
        self.createdAt = createdAt
        self.confidenceNotes = confidenceNotes
    }

    enum CodingKeys: String, CodingKey {
        case id, recordingId, suggestedTitle, executiveSummary, markedMoments,
             decisions, actionItems, openQuestions, risks, followUpDraft, provider,
             createdAt, confidenceNotes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        recordingId = try c.decode(UUID.self, forKey: .recordingId)
        suggestedTitle = try c.decodeIfPresent(String.self, forKey: .suggestedTitle)
        executiveSummary = try c.decode(String.self, forKey: .executiveSummary)
        markedMoments = try c.decodeIfPresent([MarkedMoment].self, forKey: .markedMoments) ?? []
        decisions = try c.decode([Decision].self, forKey: .decisions)
        actionItems = try c.decode([ActionItem].self, forKey: .actionItems)
        openQuestions = try c.decode([OpenQuestion].self, forKey: .openQuestions)
        risks = try c.decode([Risk].self, forKey: .risks)
        followUpDraft = try c.decode(String.self, forKey: .followUpDraft)
        provider = try c.decode(String.self, forKey: .provider)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        confidenceNotes = try c.decode([String].self, forKey: .confidenceNotes)
    }
}

extension MeetingSummary {
    /// Applies confirmed speaker identities to already-generated notes without
    /// spending another AI request. The updated transcript will also use these
    /// names if notes are regenerated later.
    mutating func renameSpeakerReferences(_ replacements: [String: String]) {
        let replacements = replacements
            .map { ($0.key.trimmingCharacters(in: .whitespacesAndNewlines), $0.value.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.0.isEmpty && !$0.1.isEmpty && $0.0.caseInsensitiveCompare($0.1) != .orderedSame }
            .sorted { $0.0.count > $1.0.count }

        guard !replacements.isEmpty else { return }

        func renamed(_ text: String) -> String {
            replacements.reduce(text) { result, replacement in
                let pattern = "(?<![\\p{L}\\p{N}])\(NSRegularExpression.escapedPattern(for: replacement.0))(?![\\p{L}\\p{N}])"
                guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                    return result
                }
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                return expression.stringByReplacingMatches(
                    in: result,
                    range: range,
                    withTemplate: NSRegularExpression.escapedTemplate(for: replacement.1)
                )
            }
        }

        suggestedTitle = suggestedTitle.map(renamed)
        executiveSummary = renamed(executiveSummary)
        markedMoments = markedMoments.map { moment in
            var moment = moment
            moment.summary = renamed(moment.summary)
            moment.transcriptExcerpt = moment.transcriptExcerpt.map(renamed)
            return moment
        }
        decisions = decisions.map { decision in
            var decision = decision
            decision.text = renamed(decision.text)
            decision.context = decision.context.map(renamed)
            return decision
        }
        actionItems = actionItems.map { item in
            var item = item
            item.title = renamed(item.title)
            item.owner = item.owner.map(renamed)
            return item
        }
        openQuestions = openQuestions.map { question in
            var question = question
            question.text = renamed(question.text)
            question.owner = question.owner.map(renamed)
            return question
        }
        risks = risks.map { risk in
            var risk = risk
            risk.title = renamed(risk.title)
            risk.description = renamed(risk.description)
            return risk
        }
        followUpDraft = renamed(followUpDraft)
        confidenceNotes = confidenceNotes.map(renamed)
    }
}

// MARK: - MarkedMoment

struct MarkedMoment: Identifiable, Codable, Equatable {
    let id: UUID
    var timestamp: TimeInterval
    var summary: String
    var transcriptExcerpt: String?

    init(id: UUID = UUID(), timestamp: TimeInterval, summary: String, transcriptExcerpt: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.summary = summary
        self.transcriptExcerpt = transcriptExcerpt
    }
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
    case uploading
    case transcribing
    case summarizing
    case preparingNotes
    case completed
    case failed

    var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .savingAudio: return "Saving audio"
        case .uploading: return "Uploading audio"
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
        case .uploading: return 1
        case .transcribing: return 2
        case .summarizing: return 3
        case .preparingNotes: return 4
        case .completed: return 5
        case .failed: return -1
        }
    }

    var isInProgress: Bool {
        switch self {
        case .savingAudio, .uploading, .transcribing, .summarizing, .preparingNotes:
            return true
        case .idle, .completed, .failed:
            return false
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
    case favorites

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "All"
        case .thisWeek: return "This week"
        case .withActionItems: return "Action items"
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
