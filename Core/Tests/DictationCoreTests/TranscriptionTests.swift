import XCTest
@testable import DictationCore
private final class FakeSocket: TranscriptionSocket, @unchecked Sendable {
    let lock = NSLock()
    var messages: [String] = []
    var replies: [String]
    var closed = false
    init(_ replies: [String]) { self.replies = replies }
    func send(_ text: String) async throws { record(text) }
    private func record(_ text: String) { lock.lock(); defer { lock.unlock() }; messages.append(text) }
    func receive() async throws -> String { try nextReply() }
    private func nextReply() throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard !replies.isEmpty else { throw DictationFailure.connection }
        return replies.removeFirst()
    }
    func close() { lock.lock(); closed = true; lock.unlock() }
}
final class TranscriptionTests: XCTestCase {
    func settings() throws -> DictationSettings {
        try ImportedConfiguration.decode(Data(#"{"openAIApiKey":"fake","anthropicApiKey":"fake","cleanupModel":"fake","cleanupPrompt":"clean","cleanupMaxTokens":400}"#.utf8)).settings
    }
    func testAppendsAreOrderedBeforeCommitAndSocketCloses() async throws {
        let socket = FakeSocket([#"{"type":"session.updated"}"#, #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"hello"}"#])
        let stream = AsyncStream<Data> { c in c.yield(Data(repeating: 1, count: 4800)); c.yield(Data([2,3])); c.finish() }
        let result = try await RealtimeTranscription.transcribe(socket: socket, chunks: stream, settings: settings())
        XCTAssertEqual(result, "hello")
        let objects = try socket.messages.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(objects.map { $0["type"] as! String }, ["session.update", "input_audio_buffer.append", "input_audio_buffer.append", "input_audio_buffer.commit"])
        XCTAssertEqual(objects[2]["audio"] as? String, Data([2,3]).base64EncodedString())
        XCTAssertTrue(socket.closed)
    }
    func testMissingTranscriptAndFailedEventAreErrors() async throws {
        for reply in [#"{"type":"conversation.item.input_audio_transcription.completed"}"#, #"{"type":"conversation.item.input_audio_transcription.failed","error":{"message":"private text"}}"#] {
            let socket = FakeSocket([#"{"type":"session.updated"}"#, reply])
            let stream = AsyncStream<Data> { c in c.yield(Data(repeating: 0, count: 4800)); c.finish() }
            do {
                _ = try await RealtimeTranscription.transcribe(socket: socket, chunks: stream, settings: settings())
                XCTFail("Expected failure")
            } catch { XCTAssertFalse(error.localizedDescription.contains("private text")) }
            XCTAssertTrue(socket.closed)
        }
    }
}

private final class WaitingSocket: TranscriptionSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var waiter: CheckedContinuation<String, Error>?
    private var initial: String?
    let failSend: Bool
    let onWait: @Sendable () -> Void
    init(ready: Bool = false, failSend: Bool = false, onWait: @escaping @Sendable () -> Void = {}) {
        self.onWait = onWait
        initial = ready ? #"{"type":"session.updated"}"# : nil
        self.failSend = failSend
    }
    func send(_ text: String) async throws {
        if failSend { throw URLError(.cannotConnectToHost) }
        try checkOpen()
    }
    private func checkOpen() throws {
        lock.lock(); defer { lock.unlock() }
        if closed { throw URLError(.cancelled) }
    }
    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed { lock.unlock(); continuation.resume(throwing: URLError(.cancelled)); return }
            if let text = initial { initial = nil; lock.unlock(); continuation.resume(returning: text); return }
            waiter = continuation; lock.unlock(); onWait()
        }
    }
    func close() {
        lock.lock(); closed = true; let continuation = waiter; waiter = nil; lock.unlock()
        continuation?.resume(throwing: URLError(.cancelled))
    }
}
extension TranscriptionTests {
    func testHandshakeTimeoutAndCancellationHaveCorrectCategory() async throws {
        let socket = WaitingSocket()
        do {
            _ = try await RealtimeTranscription.transcribe(socket: socket, chunks: AsyncStream { $0.finish() }, settings: settings(), deadlines: .init(handshake: 0.02))
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? DictationFailure, .timeout) }
        let receiving = expectation(description: "receive is suspended")
        let waiting = WaitingSocket(onWait: { receiving.fulfill() })
        let settings = try settings()
        let task = Task { try await RealtimeTranscription.transcribe(socket: waiting, chunks: AsyncStream { $0.finish() }, settings: settings) }
        await fulfillment(of: [receiving], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? DictationFailure, .cancelled) }
    }
    func testNeverEndingProducerTimesOut() async throws {
        let socket = WaitingSocket(ready: true)
        let stream = AsyncStream<Data> { _ in }
        do {
            _ = try await RealtimeTranscription.transcribe(socket: socket, chunks: stream, settings: settings(), deadlines: .init(upload: 0.02))
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? DictationFailure, .timeout) }
    }
    func testHandshakeErrorAndSendFailure() async throws {
        for (socket, expected) in [(FakeSocket([#"{"type":"error"}"#]) as any TranscriptionSocket, DictationFailure.rejected), (WaitingSocket(failSend: true), .connection)] {
            do {
                _ = try await RealtimeTranscription.transcribe(socket: socket, chunks: AsyncStream { $0.finish() }, settings: settings())
                XCTFail("Expected failure")
            } catch { XCTAssertEqual(error as? DictationFailure, expected) }
        }
    }
}
