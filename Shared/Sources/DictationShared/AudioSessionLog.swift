import Foundation
#if os(iOS)
import AVFAudio
#endif

/// One audio-session step, as a JSON line in `Library/Caches/<name>.jsonl` of the writing process's container.
/// `error` is the NSError code (`errorName` gives AVAudioSession four-char codes such as `!int`); `nowPlaying` is
/// MediaRemote's view of the Now Playing app where a step read it.
public struct AudioSessionLogEntry: Codable, Equatable, Sendable {
    public var at: Double
    public var pid: Int32
    public var step: String
    public var ok: Bool
    public var error: Int?
    public var errorName: String?
    public var errorDomain: String?
    public var otherAudioPlaying: Bool?
    public var silenceSecondaryHint: Bool?
    public var outputs: [String]?
    public var inputs: [String]?
    public var detail: String?
    public var nowPlaying: NowPlayingSnapshot?

    public init(step: String, ok: Bool = true, error: Int? = nil, errorDomain: String? = nil, otherAudioPlaying: Bool? = nil, silenceSecondaryHint: Bool? = nil,
                outputs: [String]? = nil, inputs: [String]? = nil, detail: String? = nil, nowPlaying: NowPlayingSnapshot? = nil,
                at: Double = Date().timeIntervalSince1970, pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.at = at; self.pid = pid; self.step = step; self.ok = ok
        self.error = error; self.errorName = error.flatMap(Self.fourCharCode); self.errorDomain = errorDomain
        self.otherAudioPlaying = otherAudioPlaying; self.silenceSecondaryHint = silenceSecondaryHint
        self.outputs = outputs; self.inputs = inputs; self.detail = detail; self.nowPlaying = nowPlaying
    }

    /// `560557684` → `"!int"`; nil unless all four bytes are printable ASCII.
    public static func fourCharCode(_ code: Int) -> String? {
        guard code > 0, code <= Int(UInt32.max) else { return nil }
        let bytes = (0..<4).map { UInt8((UInt32(code) >> (24 - 8 * UInt32($0))) & 0xFF) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Appends JSON lines to a file, restarting it once it passes `limit` bytes. Callers serialize writes.
public struct JSONLinesFile: Sendable {
    public let url: URL
    public let limit: Int
    public init(url: URL, limit: Int = 64 * 1024) { self.url = url; self.limit = limit }

    /// `Library/Caches/<name>` of the current process's container.
    public static func caches(_ name: String) -> JSONLinesFile? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first.map { JSONLinesFile(url: $0.appendingPathComponent(name)) }
    }

    public func append<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(value) else { return }
        data.append(0x0A)
        // Not `url.resourceValues`: the URL caches the size from the first lookup.
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        if size < limit, let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

#if os(iOS)
public extension Set where Element == SessionOption {
    var categoryOptions: AVAudioSession.CategoryOptions {
        var result: AVAudioSession.CategoryOptions = []
        for option in self {
            switch option {
            case .mixWithOthers: result.insert(.mixWithOthers)
            case .duckOthers: result.insert(.duckOthers)
            case .defaultToSpeaker: result.insert(.defaultToSpeaker)
            case .allowBluetoothA2DP: result.insert(.allowBluetoothA2DP)
            }
        }
        return result
    }
}

public extension AudioSessionLogEntry {
    /// Captures the session's other-audio flags and current route (port types such as `Speaker`, `Receiver`,
    /// `BluetoothA2DPOutput`, `MicrophoneBuiltIn`) alongside the step's outcome.
    init(step: String, session: AVAudioSession, ok: Bool? = nil, error: Error? = nil, detail: String? = nil, nowPlaying: NowPlayingSnapshot? = nil) {
        let route = session.currentRoute
        self.init(step: step, ok: ok ?? (error == nil), error: error.map { ($0 as NSError).code }, errorDomain: error.map { ($0 as NSError).domain },
                  otherAudioPlaying: session.isOtherAudioPlaying, silenceSecondaryHint: session.secondaryAudioShouldBeSilencedHint,
                  outputs: route.outputs.map(\.portType.rawValue), inputs: route.inputs.map(\.portType.rawValue), detail: detail, nowPlaying: nowPlaying)
    }
}
#endif
