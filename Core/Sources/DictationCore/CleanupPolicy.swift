import Foundation

public struct CleanupResult: Sendable {
    public let text: String
    public let cleaned: Bool
}

public enum CleanupPolicy {
    public static func finalText(raw: String, data: Data) -> String {
        result(raw: raw, data: data).text
    }
    public static func result(raw: String, data: Data) -> CleanupResult {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["stop_reason"] as? String == "end_turn",
              let content = object["content"] as? [[String: Any]] else { return CleanupResult(text: raw, cleaned: false) }
        let text = content.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let markers = ["i appreciate", "i need to clarify", "i understand you're asking", "please wrap it in",
                       "there's no actual content", "if you have actual speech-to-text", "if you have raw dictated",
                       "testing my instructions", "not a request or command directed at me", "i can't process",
                       "i'm not able to", "clarif", "could you provide", "let me know if"]
        guard !text.isEmpty, !markers.contains(where: { text.lowercased().contains($0) }) else { return CleanupResult(text: raw, cleaned: false) }
        return CleanupResult(text: text, cleaned: true)
    }
    public static func request(raw: String, key: String, settings: DictationSettings) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": settings.cleanupModel, "max_tokens": settings.cleanupMaxTokens,
            "system": settings.cleanupSystemPrompt, "stream": false,
            "messages": [["role": "user", "content": "<transcript>\(raw)</transcript>"]]
        ])
        return request
    }
    public static func clean(raw: String, key: String, settings: DictationSettings,
                             transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await fetch($0) }) async throws -> CleanupResult {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            guard !Task.isCancelled else { throw DictationFailure.cancelled }
            return CleanupResult(text: raw, cleaned: false)
        }
        guard !Task.isCancelled else { throw DictationFailure.cancelled }
        do {
            let request = try request(raw: raw, key: key, settings: settings)
            let (data, response) = try await transport(request)
            guard !Task.isCancelled else { throw DictationFailure.cancelled }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return CleanupResult(text: raw, cleaned: false) }
            return result(raw: raw, data: data)
        } catch {
            if Task.isCancelled || error is CancellationError { throw DictationFailure.cancelled }
            return CleanupResult(text: raw, cleaned: false)
        }
    }
    public static func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return try await session.data(for: request)
    }
}
