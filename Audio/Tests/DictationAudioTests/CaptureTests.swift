import XCTest
import AVFoundation
@testable import DictationAudio

final class CaptureTests: XCTestCase {
    func testConvertsAndDrainsBothSampleRates() async throws {
        for rate in [44100.0, 48000.0] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let capture = try UtteranceCapture(format: format, directory: folder)
            let stream = capture.chunks
            let collect = Task { var bytes = Data(); for await part in stream { bytes.append(part) }; return bytes }
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate / 10))!
            buffer.frameLength = buffer.frameCapacity
            for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = 0.25 }
            capture.append(buffer)
            try await capture.stop()
            let bytes = await collect.value
            XCTAssertGreaterThan(bytes.count, 4000)
            XCTAssertLessThan(bytes.count, 5200)
            XCTAssertEqual(bytes.count % 2, 0)
            XCTAssertEqual(try Data(contentsOf: capture.fileURL), bytes)
            let samples = bytes.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            XCTAssertTrue(samples.contains { abs(Int($0) - 8192) < 100 })
            capture.append(buffer) // Stopped capture must never append late callbacks.
            XCTAssertEqual(try Data(contentsOf: capture.fileURL), bytes)
        }
    }
    func testByteLimitStopsNormallyWithoutOversizedRetryFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let capture = try UtteranceCapture(format: format, directory: folder, byteLimit: 100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        capture.append(buffer)
        try await capture.stop()
        XCTAssertEqual(try Data(contentsOf: capture.fileURL).count, 100)
    }
    func testFormatMismatchAndEmptyInput() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let capture = try UtteranceCapture(format: format, directory: folder)
        capture.append(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 10)!)
        let other = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!, frameCapacity: 100)!
        other.frameLength = 100; capture.append(other)
        do { try await capture.stop(); XCTFail("Must reject changed format") }
        catch { XCTAssertEqual(error as? CaptureFailure, .format) }
    }
    func testLargeTapAndNewCaptureReplacesOldFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let capture = try UtteranceCapture(format: format, directory: folder)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 19200)!
        buffer.frameLength = 19200; capture.append(buffer)
        try await capture.stop()
        XCTAssertGreaterThan(try Data(contentsOf: capture.fileURL).count, 18000)
        let second = try UtteranceCapture(format: format, directory: folder)
        try await second.stop()
        XCTAssertEqual(try Data(contentsOf: second.fileURL).count, 0)
    }
    func testUnreadStreamPreservesFullRecording() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let overflow = expectation(description: "network detached")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let capture = try UtteranceCapture(format: format, directory: folder, onFailure: { _ in XCTFail("disk capture must continue") }, onStreamOverflow: { overflow.fulfill() })
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        for _ in 0..<550 {
            capture.append(buffer)
            try await Task.sleep(nanoseconds: 1_000_000) // Give the conversion queue time; test network backlog, not raw-copy backlog.
        }
        try await capture.stop()
        await fulfillment(of: [overflow], timeout: 1)
        XCTAssertGreaterThan(try Data(contentsOf: capture.fileURL).count, 2_600_000)
    }
    func testSmallTapHandshakeBacklogFitsFifteenSeconds() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let capture = try UtteranceCapture(format: format, directory: folder,
            onFailure: { _ in XCTFail("capture failed") }, onStreamOverflow: { XCTFail("15 second handshake must fit") })
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024
        for _ in 0..<704 { // 15.02 seconds; deliberately no stream consumer during the handshake.
            capture.append(buffer)
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try await capture.stop()
        let complete = await capture.streamIsComplete()
        XCTAssertTrue(complete)
        var streamed = Data()
        for await packet in capture.chunks { streamed.append(packet) }
        XCTAssertEqual(streamed, try Data(contentsOf: capture.fileURL))
        XCTAssertGreaterThan(streamed.count, 700_000)
    }
}
