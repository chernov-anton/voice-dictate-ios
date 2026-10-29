import Foundation

public enum DictationFailure: String, Error, LocalizedError, Sendable {
    case invalidConfiguration = "Configuration is missing required keys or settings."
    case connection = "Could not connect to transcription. Retry the saved recording."
    case timeout = "Transcription timed out. Retry the saved recording."
    case invalidResponse = "Transcription returned an invalid response."
    case rejected = "Transcription request failed. Check your account and settings."
    case cancelled = "Dictation cancelled."
    case audioOverflow = "Audio processing could not keep up. Recording stopped."
    case tooLong = "Recording exceeded the five-minute audio limit."
    case tooShort = "Recording too short."
    public var errorDescription: String? { rawValue }
}

public struct DictationSettings: Codable, Sendable {
    public let cleanupModel: String
    public let cleanupPrompt: String
    public let cleanupMaxTokens: Int
    public let transcriptionModel: String
    public let transcriptionPrompt: String
    public let transcriptionKeywords: [String]
    public var cleanupSystemPrompt: String {
        guard !transcriptionKeywords.isEmpty else { return cleanupPrompt }
        return "Names/terms that may appear (correct the spelling if the transcript seems to mangle one of these): "
            + transcriptionKeywords.joined(separator: ", ") + "\n\n" + cleanupPrompt
    }
}
public struct APICredentials: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public let openAIApiKey: String
    public let anthropicApiKey: String
}
public struct ImportedConfiguration: Sendable {
    public let credentials: APICredentials
    public let settings: DictationSettings
    public static func decode(_ data: Data) throws -> Self {
        struct Payload: Decodable {
            let openAIApiKey: String
            let anthropicApiKey: String
            let cleanupModel: String
            let cleanupPrompt: String
            let cleanupMaxTokens: Int
            let transcriptionModel: String?
            let transcriptionPrompt: String?
            let transcriptionKeywords: [String]?
        }
        guard data.count <= 1_048_576, let value = try? JSONDecoder().decode(Payload.self, from: data),
              !value.openAIApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.anthropicApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.cleanupModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !value.cleanupPrompt.isEmpty,
              (1...32768).contains(value.cleanupMaxTokens),
              !(value.transcriptionModel ?? "gpt-transcribe").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DictationFailure.invalidConfiguration }
        return Self(credentials: APICredentials(openAIApiKey: value.openAIApiKey.trimmingCharacters(in: .whitespacesAndNewlines), anthropicApiKey: value.anthropicApiKey.trimmingCharacters(in: .whitespacesAndNewlines)),
                    settings: DictationSettings(cleanupModel: value.cleanupModel.trimmingCharacters(in: .whitespacesAndNewlines), cleanupPrompt: value.cleanupPrompt,
                        cleanupMaxTokens: value.cleanupMaxTokens, transcriptionModel: (value.transcriptionModel ?? "gpt-transcribe").trimmingCharacters(in: .whitespacesAndNewlines),
                        transcriptionPrompt: value.transcriptionPrompt ?? "", transcriptionKeywords: value.transcriptionKeywords ?? []))
    }
}
