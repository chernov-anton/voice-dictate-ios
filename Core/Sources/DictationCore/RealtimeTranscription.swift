import Foundation

/// close() is idempotent and must unblock pending/future send and receive calls with errors.
public protocol TranscriptionSocket: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close()
}
public final class OpenAISocket: TranscriptionSocket, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    public init(key: String) {
        let configuration = URLSessionConfiguration.ephemeral
        session = URLSession(configuration: configuration)
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        task = session.webSocketTask(with: request)
        task.resume()
    }
    public func send(_ text: String) async throws { try await task.send(.string(text)) }
    public func receive() async throws -> String {
        let message: URLSessionWebSocketTask.Message
        do { message = try await task.receive() } catch {
            if let status = (task.response as? HTTPURLResponse)?.statusCode, [401, 403].contains(status) {
                throw DictationFailure.rejected
            }
            throw error
        }
        switch message {
        case .string(let text): return text
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else { throw DictationFailure.invalidResponse }
            return text
        @unknown default: throw DictationFailure.invalidResponse
        }
    }
    public func close() { task.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
}

public struct TranscriptionDeadlines: Sendable {
    public var handshake: Double = 15
    public var upload: Double = 330
    public var completion: Double = 30
    public init(handshake: Double = 15, upload: Double = 330, completion: Double = 30) {
        self.handshake = handshake; self.upload = upload; self.completion = completion
    }
}
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOut = false
    func set() { lock.lock(); timedOut = true; lock.unlock() }
    func read() -> Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
}
public enum RealtimeTranscription {
    public static func transcribe(socket: any TranscriptionSocket, chunks: AsyncStream<Data>, settings: DictationSettings, deadlines: TranscriptionDeadlines = .init()) async throws -> String {
        try await withTaskCancellationHandler {
            defer { socket.close() }
            do {
                try await deadline(seconds: deadlines.handshake, socket: socket) {
                    var transcription: [String: Any] = ["model": settings.transcriptionModel]
                    if !settings.transcriptionPrompt.isEmpty { transcription["prompt"] = settings.transcriptionPrompt }
                    if !settings.transcriptionKeywords.isEmpty { transcription["keywords"] = settings.transcriptionKeywords }
                    try await send(["type": "session.update", "session": ["type": "transcription", "audio": ["input": [
                        "format": ["type": "audio/pcm", "rate": 24000], "transcription": transcription,
                        "turn_detection": NSNull()]]]], socket: socket)
                    while true {
                        let event = try decode(await socket.receive())
                        if event["type"] as? String == "session.updated" { return }
                        if event["type"] as? String == "error" { throw DictationFailure.rejected }
                    }
                }
                // This single consumer awaits every send; commit cannot overtake an append.
                // A whole-utterance deadline also bounds a wedged send or a producer that never finishes.
                let bytes: Int = try await deadline(seconds: deadlines.upload, socket: socket) {
                    var bytes = 0
                    for await chunk in chunks {
                        try Task.checkCancellation()
                        bytes += chunk.count
                        guard bytes <= 14_400_000 else { throw DictationFailure.tooLong }
                        try await send(["type": "input_audio_buffer.append", "audio": chunk.base64EncodedString()], socket: socket)
                    }
                    try Task.checkCancellation()
                    return bytes
                }
                guard bytes >= 4800 else { throw DictationFailure.tooShort }
                return try await deadline(seconds: deadlines.completion, socket: socket) {
                        try await send(["type": "input_audio_buffer.commit"], socket: socket)
                        while true {
                            let event = try decode(await socket.receive())
                            switch event["type"] as? String {
                            case "conversation.item.input_audio_transcription.completed":
                                guard let text = event["transcript"] as? String else { throw DictationFailure.invalidResponse }
                                return text.trimmingCharacters(in: .whitespacesAndNewlines)
                            case "conversation.item.input_audio_transcription.failed", "error":
                                throw DictationFailure.rejected
                            default: continue
                            }
                        }
                }
            } catch let error as DictationFailure {
                throw Task.isCancelled ? DictationFailure.cancelled : error
            }
            catch is CancellationError { throw DictationFailure.cancelled }
            catch { throw Task.isCancelled ? DictationFailure.cancelled : DictationFailure.connection }
        } onCancel: { socket.close() }
    }
    private static func send(_ object: [String: Any], socket: any TranscriptionSocket) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else { throw DictationFailure.invalidResponse }
        try await socket.send(text)
    }
    private static func decode(_ text: String) throws -> [String: Any] {
        guard let event = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw DictationFailure.invalidResponse
        }
        return event
    }
    private static func deadline<T: Sendable>(seconds: Double, socket: any TranscriptionSocket,
                                             operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let flag = TimeoutFlag()
        do { return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                flag.set()
                socket.close() // Unblocks receive/send before waiting for the cancelled child.
                throw DictationFailure.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        } } catch {
            if flag.read() { throw DictationFailure.timeout }
            throw error
        }
    }
}
