import Foundation
import Darwin

/// The private MediaRemote.framework (what Control Center uses), resolved at runtime with dlopen/dlsym so a
/// missing symbol only disables it. Personal-sideload only, like `HostAppReturn`'s private calls.
/// Signatures were checked against the iOS 26.3 runtime: `MRMediaRemoteSendCommand` always returns true, so
/// commands use `MRMediaRemoteSendCommandWithReply(command, options, queue, reply)`, whose reply is logged.
/// `mediaremoted` sends an unentitled client's command to the Now Playing app ("missing entitlement needed to
/// send command to arbitrary apps. Sending to NowPlayingApp instead"); now-playing reads need entitlements
/// third-party apps can't get, so `nowPlaying` may come back false/0/nil. Every call is non-blocking except the
/// `timeout` waits, which callers make off the main thread.
public final class MediaRemote: @unchecked Sendable {
    public static let shared = MediaRemote()

    private typealias Reply = @convention(block) (AnyObject?) -> Void
    private typealias SendWithReply = @convention(c) (UInt32, CFDictionary?, DispatchQueue?, Reply?) -> UInt8
    // The getters keep their reply block and call it later on the queue, so it must be @escaping: a non-escaping
    // block traps the moment the callee retains it (swift_isEscapingClosureAtFileLocation).
    private typealias IsPlaying = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    private typealias PID = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void
    private typealias Client = @convention(c) (DispatchQueue, @escaping @convention(block) (AnyObject?) -> Void) -> Void
    private typealias BundleID = @convention(c) (AnyObject?) -> Unmanaged<CFString>?

    private let send: SendWithReply?
    private let isPlaying: IsPlaying?
    private let pid: PID?
    private let client: Client?
    private let bundleID: BundleID?
    private let replies = DispatchQueue(label: "voicedictate.mediaRemote", qos: .userInitiated, attributes: .concurrent)

    /// Symbols that did not resolve (empty when all did); `"dlopen"` if the framework didn't load.
    public let missing: [String]
    /// Whether Pause/Play can be sent at all.
    public var canSend: Bool { send != nil }

    private convenience init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)
        self.init(resolve: handle.map { handle in { dlsym(handle, $0) } })
    }

    /// `resolve` looks up a symbol's address; nil means the framework didn't load. Tests pass fakes.
    init(resolve: ((String) -> UnsafeMutableRawPointer?)?) {
        guard let resolve else {
            send = nil; isPlaying = nil; pid = nil; client = nil; bundleID = nil; missing = ["dlopen"]; return
        }
        var missing: [String] = []
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = resolve(name) else { missing.append(name); return nil }
            return unsafeBitCast(pointer, to: type)
        }
        send = symbol("MRMediaRemoteSendCommandWithReply", as: SendWithReply.self)
        isPlaying = symbol("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: IsPlaying.self)
        pid = symbol("MRMediaRemoteGetNowPlayingApplicationPID", as: PID.self)
        client = symbol("MRMediaRemoteGetNowPlayingClient", as: Client.self)
        bundleID = symbol("MRNowPlayingClientGetBundleIdentifier", as: BundleID.self)
        self.missing = missing
    }

    /// Sends `command` to the Now Playing app and waits up to `timeout` for mediaremoted's reply.
    /// nil when the command can't be sent (symbol missing or the call refused it).
    public func send(_ command: MediaRemoteCommand, timeout: TimeInterval) -> MediaRemoteSendResult? {
        guard let send else { return nil }
        let box = Box<MediaRemoteSendResult>()
        let done = DispatchSemaphore(value: 0)
        let reply: Reply = { value in
            box.set(MediaRemoteSendResult(replied: true, handled: Self.handled(value), reply: Self.describe(value)))
            done.signal()
        }
        guard send(command.code, nil, replies, reply) != 0 else { return nil }
        _ = done.wait(timeout: .now() + timeout)
        return box.value ?? MediaRemoteSendResult(replied: false, handled: nil, reply: nil)
    }

    /// Now Playing app state, each field nil if its symbol is missing or no answer came within `timeout`.
    public func nowPlaying(timeout: TimeInterval) -> NowPlayingSnapshot {
        let playing = Box<Bool>(), process = Box<Int32>(), bundle = Box<String>()
        let group = DispatchGroup()
        if let isPlaying { group.enter(); isPlaying(replies) { playing.set($0); group.leave() } }
        if let pid { group.enter(); pid(replies) { process.set($0); group.leave() } }
        if let client, let bundleID {
            group.enter()
            client(replies) { value in
                if let value, let id = bundleID(value)?.takeUnretainedValue() { bundle.set(id as String) }
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + timeout)
        return NowPlayingSnapshot(isPlaying: playing.value, pid: process.value, bundle: bundle.value)
    }

    /// The reply is an array of handler statuses on current systems; 0 means a handler accepted the command.
    private static func handled(_ value: AnyObject?) -> Bool? {
        guard let statuses = value as? [NSNumber] else { return nil }
        return statuses.contains { $0.intValue == 0 }
    }

    private static func describe(_ value: AnyObject?) -> String {
        guard let value else { return "nil" }
        if let statuses = value as? [NSNumber] { return "[" + statuses.map { $0.stringValue }.joined(separator: ",") + "]" }
        return String(String(describing: value).prefix(200))
    }

    /// Written by reply blocks on `replies`, read after the wait (possibly while a late reply still writes).
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?
        func set(_ value: T) { lock.lock(); stored = value; lock.unlock() }
        var value: T? { lock.lock(); defer { lock.unlock() }; return stored }
    }
}
