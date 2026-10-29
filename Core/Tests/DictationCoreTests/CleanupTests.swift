import XCTest
@testable import DictationCore
final class CleanupTests: XCTestCase {
    let raw = "full original transcript"
    func response(_ reason: String, _ text: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["stop_reason": reason, "content": [["type": "text", "text": text]]])
    }
    func testOnlyCompleteNonemptyNonrefusalOutputReplacesRaw() throws {
        XCTAssertEqual(CleanupPolicy.finalText(raw: raw, data: try response("end_turn", "Clean text.")), "Clean text.")
        for reason in ["max_tokens", "stop_sequence", "refusal"] {
            XCTAssertEqual(CleanupPolicy.finalText(raw: raw, data: try response(reason, "fragment")), raw)
        }
        for text in ["", "  ", "I need to clarify what you mean"] {
            XCTAssertEqual(CleanupPolicy.finalText(raw: raw, data: try response("end_turn", text)), raw)
        }
        XCTAssertEqual(CleanupPolicy.finalText(raw: raw, data: Data("bad".utf8)), raw)
    }
    func testSettingsImportAndPromptParity() throws {
        let data = Data(#"{"openAIApiKey":"fake-openai","anthropicApiKey":"fake-anthropic","cleanupModel":"configured-model","cleanupPrompt":"Keep meaning","cleanupMaxTokens":400,"transcriptionModel":"gpt-transcribe","transcriptionKeywords":["Acme"]}"#.utf8)
        let imported = try ImportedConfiguration.decode(data)
        XCTAssertEqual(imported.settings.transcriptionModel, "gpt-transcribe")
        XCTAssertEqual(imported.settings.cleanupSystemPrompt, "Names/terms that may appear (correct the spelling if the transcript seems to mangle one of these): Acme\n\nKeep meaning")
        XCTAssertThrowsError(try ImportedConfiguration.decode(Data("{}".utf8)))
        let request = try CleanupPolicy.request(raw: "hello", key: "fake", settings: imported.settings)
        XCTAssertEqual(request.timeoutInterval, 20)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "configured-model")
        XCTAssertEqual(body["stream"] as? Bool, false)
    }
    func testIdenticalAcceptedTextIsStillCleaned() throws {
        let result = CleanupPolicy.result(raw: raw, data: try response("end_turn", raw))
        XCTAssertTrue(result.cleaned)
        XCTAssertEqual(result.text, raw)
    }
    func testCleanupCancellationDoesNotBecomeRawSuccess() async throws {
        let settings = DictationSettings(cleanupModel: "fake", cleanupPrompt: "clean", cleanupMaxTokens: 20,
                                        transcriptionModel: "fake", transcriptionPrompt: "", transcriptionKeywords: [])
        do {
            _ = try await CleanupPolicy.clean(raw: raw, key: "fake", settings: settings) { _ in
                throw CancellationError()
            }
            XCTFail("Cancellation must propagate")
        } catch { XCTAssertEqual(error as? DictationFailure, .cancelled) }
        let fallback = try await CleanupPolicy.clean(raw: raw, key: "fake", settings: settings) { _ in
            throw URLError(.notConnectedToInternet)
        }
        XCTAssertEqual(fallback.text, raw)
        XCTAssertFalse(fallback.cleaned)
    }
    func testImportTrimsAndRedactsCredentials() throws {
        var object: [String: Any] = ["openAIApiKey": " fake-openai\n", "anthropicApiKey": " fake-anthropic ",
                                    "cleanupModel": " model ", "cleanupPrompt": "clean", "cleanupMaxTokens": 20]
        let imported = try ImportedConfiguration.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(imported.credentials.openAIApiKey, "fake-openai")
        XCTAssertEqual(imported.credentials.anthropicApiKey, "fake-anthropic")
        XCTAssertEqual(imported.settings.cleanupModel, "model")
        XCTAssertEqual(String(describing: imported.credentials), "<redacted>")
        XCTAssertEqual(String(reflecting: imported.credentials), "<redacted>")
        object["transcriptionModel"] = " \n"
        XCTAssertThrowsError(try ImportedConfiguration.decode(JSONSerialization.data(withJSONObject: object)))
    }
}
