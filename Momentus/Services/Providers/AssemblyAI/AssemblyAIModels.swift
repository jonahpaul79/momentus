import Foundation

// MARK: - Upload

struct AssemblyAIUploadResponse: Decodable {
    let uploadURL: String
    enum CodingKeys: String, CodingKey { case uploadURL = "upload_url" }
}

// MARK: - Transcript Job

struct AssemblyAITranscriptRequest: Encodable {
    let audioURL: String
    let speechModels: [String]
    let speakerLabels: Bool
    let languageDetection: Bool
    let punctuate: Bool
    let formatText: Bool

    enum CodingKeys: String, CodingKey {
        case audioURL = "audio_url"
        case speechModels = "speech_models"
        case speakerLabels = "speaker_labels"
        case languageDetection = "language_detection"
        case punctuate
        case formatText = "format_text"
    }

    init(audioURL: String) {
        self.audioURL = audioURL
        self.speechModels = ["universal-3-pro"]
        self.speakerLabels = true
        self.languageDetection = true
        self.punctuate = true
        self.formatText = true
    }
}

struct AssemblyAITranscriptResponse: Decodable {
    let id: String
    let status: String          // "queued" | "processing" | "completed" | "error"
    let text: String?
    let utterances: [AssemblyAIUtterance]?
    let languageCode: String?
    let confidence: Double?
    let audioDuration: Double?  // seconds
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id, status, text, utterances, confidence, error
        case languageCode = "language_code"
        case audioDuration = "audio_duration"
    }

    var isCompleted: Bool { status == "completed" }
    var isFailed: Bool { status == "error" }
}

struct AssemblyAIUtterance: Decodable {
    let speaker: String
    let text: String
    let start: Int      // milliseconds
    let end: Int        // milliseconds
    let confidence: Double
    let words: [AssemblyAIWord]

    var startSeconds: TimeInterval { TimeInterval(start) / 1000.0 }
    var endSeconds: TimeInterval { TimeInterval(end) / 1000.0 }
}

struct AssemblyAIWord: Decodable {
    let text: String
    let start: Int
    let end: Int
    let confidence: Double
    let speaker: String?
}

// MARK: - LeMUR

struct AssemblyAILeMURRequest: Encodable {
    let transcriptIDs: [String]?
    let inputText: String?
    let prompt: String
    let finalModel: String
    let maxOutputSize: Int

    enum CodingKeys: String, CodingKey {
        case transcriptIDs = "transcript_ids"
        case inputText = "input_text"
        case prompt
        case finalModel = "final_model"
        case maxOutputSize = "max_output_size"
    }

    static func withTranscriptIDs(_ ids: [String], prompt: String) -> Self {
        AssemblyAILeMURRequest(
            transcriptIDs: ids, inputText: nil,
            prompt: prompt, finalModel: "default", maxOutputSize: 2000
        )
    }

    static func withInputText(_ text: String, prompt: String) -> Self {
        AssemblyAILeMURRequest(
            transcriptIDs: nil, inputText: text,
            prompt: prompt, finalModel: "default", maxOutputSize: 2000
        )
    }
}

struct AssemblyAILeMURResponse: Decodable {
    let requestID: String
    let response: String

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case response
    }
}

// MARK: - Error Response

struct AssemblyAIErrorBody: Decodable {
    let error: String
}
