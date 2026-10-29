import XCTest
import Dispatch
@testable import DictationShared

/// Fake MediaRemote symbols that behave like the real ones: they keep the reply block and call it later on the
/// given queue. A reply block typed non-escaping traps (`swift_isEscapingClosureAtFileLocation`) as soon as the
/// callee keeps it, which crashed the keyboard on every hold of the record pad.
final class MediaRemoteTests: XCTestCase {
    private typealias Reply = @convention(block) (AnyObject?) -> Void
    private typealias SendWithReply = @convention(c) (UInt32, CFDictionary?, DispatchQueue?, Reply?) -> UInt8
    private typealias IsPlaying = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    private typealias PID = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void
    private typealias Client = @convention(c) (DispatchQueue, @escaping @convention(block) (AnyObject?) -> Void) -> Void
    private typealias BundleID = @convention(c) (AnyObject?) -> Unmanaged<CFString>?

    private struct Later<T>: @unchecked Sendable { let value: T }

    private static func remote(_ symbols: [String: UnsafeMutableRawPointer]) -> MediaRemote {
        MediaRemote(resolve: { symbols[$0] })
    }

    func testNowPlayingRepliesArriveAfterTheCallReturns() {
        let isPlaying: IsPlaying = { queue, reply in let r = Later(value: reply); queue.async { r.value(true) } }
        let pid: PID = { queue, reply in let r = Later(value: reply); queue.async { r.value(42) } }
        let client: Client = { queue, reply in let r = Later(value: reply); queue.async { r.value(NSObject()) } }
        let bundleID: BundleID = { _ in Unmanaged.passRetained("com.example.player" as CFString) }
        let remote = Self.remote([
            "MRMediaRemoteGetNowPlayingApplicationIsPlaying": unsafeBitCast(isPlaying, to: UnsafeMutableRawPointer.self),
            "MRMediaRemoteGetNowPlayingApplicationPID": unsafeBitCast(pid, to: UnsafeMutableRawPointer.self),
            "MRMediaRemoteGetNowPlayingClient": unsafeBitCast(client, to: UnsafeMutableRawPointer.self),
            "MRNowPlayingClientGetBundleIdentifier": unsafeBitCast(bundleID, to: UnsafeMutableRawPointer.self),
        ])
        XCTAssertEqual(remote.nowPlaying(timeout: 2), NowPlayingSnapshot(isPlaying: true, pid: 42, bundle: "com.example.player"))
    }

    func testNowPlayingWithoutAnswersIsUnknownAfterTheTimeout() {
        // mediaremoted may never answer an unentitled client: the blocks are kept but not called.
        let isPlaying: IsPlaying = { _, reply in let r = Later(value: reply); DispatchQueue.global().asyncAfter(deadline: .now() + 5) { _ = r } }
        let remote = Self.remote(["MRMediaRemoteGetNowPlayingApplicationIsPlaying": unsafeBitCast(isPlaying, to: UnsafeMutableRawPointer.self)])
        XCTAssertEqual(remote.missing, ["MRMediaRemoteSendCommandWithReply", "MRMediaRemoteGetNowPlayingApplicationPID",
                                        "MRMediaRemoteGetNowPlayingClient", "MRNowPlayingClientGetBundleIdentifier"])
        XCTAssertFalse(remote.canSend)
        XCTAssertEqual(remote.nowPlaying(timeout: 0.1), NowPlayingSnapshot(isPlaying: nil, pid: nil, bundle: nil))
    }

    func testSendRepliesArriveAfterTheCallReturns() {
        let send: SendWithReply = { command, _, queue, reply in
            guard let queue, let reply else { return 0 }
            let r = Later(value: reply)
            queue.async { r.value([NSNumber(value: command == 1 ? 0 : 3)] as NSArray) }
            return 1
        }
        let remote = Self.remote(["MRMediaRemoteSendCommandWithReply": unsafeBitCast(send, to: UnsafeMutableRawPointer.self)])
        XCTAssertEqual(remote.send(.pause, timeout: 2), MediaRemoteSendResult(replied: true, handled: true, reply: "[0]"))
        XCTAssertEqual(remote.send(.play, timeout: 2), MediaRemoteSendResult(replied: true, handled: false, reply: "[3]"))
    }

    func testFrameworkThatDidNotLoadSendsNothing() {
        let remote = MediaRemote(resolve: nil)
        XCTAssertEqual(remote.missing, ["dlopen"])
        XCTAssertNil(remote.send(.pause, timeout: 0.1))
        XCTAssertEqual(remote.nowPlaying(timeout: 0.1), NowPlayingSnapshot(isPlaying: nil, pid: nil, bundle: nil))
    }
}
