import AVFoundation
import Foundation

public enum CaptureFailure: String, Error, LocalizedError {
    case format = "Microphone format is unavailable. Activate again."
    case overflow = "Audio processing could not keep up. Recording stopped."
    case conversion = "Audio conversion failed. Activate again."
    case storage = "Recording could not be saved. Check available storage."
    case tooLong = "Recording reached the five-minute audio limit."
    public var errorDescription: String? { rawValue }
}

/// One instance per utterance. The lock orders enqueue vs stop; the queue owns converter/file state.
public final class UtteranceCapture: @unchecked Sendable {
    public let chunks: AsyncStream<Data>
    public let fileURL: URL
    private let continuation: AsyncStream<Data>.Continuation
    private let queue = DispatchQueue(label: "voice-dictate.pcm")
    private let lock = NSLock()
    private var accepting = true
    private var pending = 0
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private var file: FileHandle?
    private var failure: CaptureFailure?
    private var bytes = 0
    private var capped = false
    private var streamDetached = false
    private var pendingStream = Data()
    private let byteLimit: Int
    private let onLimit: @Sendable () -> Void
    private let onStreamOverflow: @Sendable () -> Void
    private let onFailure: @Sendable (CaptureFailure) -> Void

    public init(format: AVAudioFormat, directory: URL, byteLimit: Int = 14_400_000, onFailure: @escaping @Sendable (CaptureFailure) -> Void = { _ in },
                onLimit: @escaping @Sendable () -> Void = {}, onStreamOverflow: @escaping @Sendable () -> Void = {}) throws {
        guard let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: output) else { throw CaptureFailure.format }
        self.onFailure = onFailure; self.onLimit = onLimit; self.onStreamOverflow = onStreamOverflow
        self.converter = converter; outputFormat = output; self.byteLimit = byteLimit
        let pair = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(512))
        chunks = pair.stream; continuation = pair.continuation
        fileURL = directory.appendingPathComponent("retry.pcm")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var directory = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            // Caller starts only after the previous capture's stop has drained.
            try Data().write(to: fileURL, options: .atomic)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: fileURL.path)
            #endif
            file = try FileHandle(forWritingTo: fileURL)
        } catch { throw CaptureFailure.storage }
    }
    deinit { continuation.finish(); try? file?.close() }

    public func append(_ input: AVAudioPCMBuffer) {
        lock.lock()
        guard accepting, input.frameLength > 0 else { lock.unlock(); return }
        guard input.format == converter.inputFormat else {
            accepting = false; queue.async { self.fail(.format) }; lock.unlock(); return
        }
        // Bound allocations and queued conversion work, even if disk or converter stalls.
        guard pending < 32, input.frameLength <= 24000,
              let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else {
            accepting = false
            queue.async { self.fail(.overflow) }
            lock.unlock(); return
        }
        copy.frameLength = input.frameLength
        let source = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<source.count {
            guard let src = source[index].mData, let dst = target[index].mData else {
                accepting = false; queue.async { self.fail(.format) }; lock.unlock(); return
            }
            memcpy(dst, src, Int(min(source[index].mDataByteSize, target[index].mDataByteSize)))
        }
        pending += 1
        queue.async {
            defer { self.lock.lock(); self.pending -= 1; self.lock.unlock() }
            guard self.failure == nil, !self.capped else { return }
            do { try self.convert(copy) } catch let error as CaptureFailure { self.fail(error) }
            catch { self.fail(.conversion) }
        }
        lock.unlock()
    }

    public func stop() async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            lock.lock(); accepting = false
            queue.async {
                if self.file != nil {
                    if self.failure == nil && !self.capped {
                        do { try self.convert(nil) } catch let error as CaptureFailure { self.fail(error) }
                        catch { self.fail(.conversion) }
                    }
                    do { try self.file?.synchronize(); try self.file?.close() }
                    catch { self.fail(.storage) }
                    self.file = nil
                }
                if self.failure == nil { self.flushStream() }
                self.continuation.finish()
                if let failure = self.failure { done.resume(throwing: failure) }
                else { done.resume() }
            }
            lock.unlock()
        }
    }
    /// Called when networking ends early. Conversion/file capture may continue until Stop.
    public func detachStream() {
        queue.async { self.streamDetached = true; self.pendingStream.removeAll(); self.continuation.finish() }
    }
    public func streamIsComplete() async -> Bool {
        await withCheckedContinuation { done in
            queue.async { done.resume(returning: !self.streamDetached) }
        }
    }
    public static func discard(directory: URL) throws {
        let url = directory.appendingPathComponent("retry.pcm")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func fail(_ error: CaptureFailure) {
        let first = failure == nil
        if first { failure = error }
        lock.lock(); accepting = false; lock.unlock()
        continuation.finish()
        if first { onFailure(error) }
    }
    private func emit(_ data: Data) {
        if case .dropped = continuation.yield(data) {
            streamDetached = true; pendingStream.removeAll(); continuation.finish(); onStreamOverflow()
        }
    }
    private func flushStream() {
        guard !streamDetached, !pendingStream.isEmpty else { return }
        let remainder = pendingStream; pendingStream.removeAll(); emit(remainder)
    }
    private func convert(_ input: AVAudioPCMBuffer?) throws {
        var supplied = false
        // Each tap is <=24000 frames; 64 output blocks is comfortably above its maximum conversion.
        for _ in 0..<64 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else { throw CaptureFailure.conversion }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if let input, !supplied { supplied = true; state.pointee = .haveData; return input }
                state.pointee = input == nil ? .endOfStream : .noDataNow
                return nil
            }
            guard error == nil, status != .error else { throw CaptureFailure.conversion }
            if output.frameLength > 0 {
                let size = min(Int(output.frameLength) * 2, max(0, byteLimit - bytes) / 2 * 2)
                guard let pointer = output.int16ChannelData?[0] else { throw CaptureFailure.conversion }
                let data = Data(bytes: pointer, count: size)
                do { try file?.write(contentsOf: data) } catch { throw CaptureFailure.storage }
                bytes += size
                if !streamDetached {
                    pendingStream.append(data)
                    // Fixed 100 ms packets make the 512-slot queue cover 51.2 seconds,
                    // independent of the microphone's tap buffer size.
                    while pendingStream.count >= 4800 && !streamDetached {
                        let packet = Data(pendingStream.prefix(4800))
                        pendingStream.removeFirst(4800)
                        emit(packet)
                    }
                }
                if bytes >= byteLimit / 2 * 2 {
                    capped = true
                    lock.lock(); accepting = false; lock.unlock()
                    flushStream(); continuation.finish(); onLimit(); return
                }
            }
            if status == .inputRanDry || status == .endOfStream { return }
        }
        throw CaptureFailure.conversion
    }
}
