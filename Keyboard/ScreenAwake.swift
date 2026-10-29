import UIKit
import os
import DictationShared

/// Asks iOS not to dim/lock the display while the record pad is held: a stationary finger does not reset
/// the Auto-Lock idle timer, and locking dismisses the keyboard, which ends the hold.
/// Personal-sideload only: `UIApplication.sharedApplication` is extension-unavailable at compile time, so it is
/// looked up at runtime. UIKit applies `idleTimerDisabled` to this process's scenes; whether SpringBoard honours
/// that for a keyboard extension is unverified; the log records `app`, `scenes` and `readback` to show it.
/// Each transition goes to os_log category `screenAwake` and, as one JSON line, to `Library/Caches/screen-awake.jsonl`
/// in the keyboard's container (restarts past 64 KB); fetch it like `launch-timing.jsonl`.
@MainActor
final class ScreenAwake {
    private static let log = Logger(subsystem: Identifiers.logSubsystem, category: "screenAwake")
    nonisolated private static let file = DispatchQueue(label: "voicedictate.screenAwake", qos: .utility)
    private var engagedAt: TimeInterval?

    /// Idempotent; logs only transitions. `cause` says why a hold ended (touchUp, touchCancel, disappear, reset).
    func set(_ on: Bool, cause: String) {
        guard on != (engagedAt != nil) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let heldFor = engagedAt.map { now - $0 }
        engagedAt = on ? now : nil
        let app = Self.application()
        app?.isIdleTimerDisabled = on
        let scenes = Self.sceneCount()
        let readback = app?.isIdleTimerDisabled
        let event = on ? "engage" : "release"
        let held = heldFor.map { String(format: "%.1f", $0) }
        Self.log.notice("screen awake \(event, privacy: .public) cause=\(on ? "hold" : cause, privacy: .public) app=\(app != nil) scenes=\(scenes) readback=\(readback.map(String.init) ?? "nil", privacy: .public) heldFor=\(held ?? "-", privacy: .public)s")
        var line = "{\"at\":\(String(format: "%.3f", Date().timeIntervalSince1970)),\"pid\":\(getpid()),\"event\":\"\(event)\""
        line += ",\"cause\":\"\(on ? "hold" : cause)\",\"app\":\(app != nil),\"scenes\":\(scenes)"
        line += ",\"readback\":\(readback.map(String.init) ?? "null"),\"heldFor\":\(held ?? "null")}\n"
        Self.file.async { Self.append(line) }
    }

    /// `UIApplication.sharedApplication`, which exists in extension processes but is hidden from extension code.
    private static func application() -> UIApplication? {
        let selector = NSSelectorFromString("sharedApplication")
        let type: AnyObject = UIApplication.self
        guard type.responds(to: selector) else { return nil }
        return type.perform(selector)?.takeUnretainedValue() as? UIApplication
    }

    /// The scenes UIKit's idle-timer setter updates (`+[UIScene _scenesIncludingInternal:YES]`); -1 if unavailable.
    private static func sceneCount() -> Int {
        let selector = NSSelectorFromString("_scenesIncludingInternal:")
        guard let type = UIScene.self as AnyObject as? NSObject, type.responds(to: selector) else { return -1 }
        typealias Scenes = @convention(c) (AnyObject, Selector, Bool) -> NSArray?
        let call = unsafeBitCast(type.method(for: selector), to: Scenes.self)
        return call(type, selector, true)?.count ?? -1
    }

    nonisolated private static func append(_ line: String) {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let url = caches.appendingPathComponent("screen-awake.jsonl")
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size < 64 * 1024, let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
