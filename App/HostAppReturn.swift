import UIKit
import os
import DictationShared

/// Returns to the app the user was typing in after a keyboard-triggered activation. Personal-sideload only:
/// it reads the keyboard host and opens an app through private UIKit/LaunchServices API. Every step is
/// looked up at runtime and checked, so any failure just means "no automatic return".
@MainActor
final class HostAppReturn {
    private static let log = Logger(subsystem: Identifiers.logSubsystem, category: "hostReturn")
    private var task: Task<Void, Never>?

    /// Call on URL receipt, before activating. `activate` runs the activation and reports whether the
    /// microphone is ready; the host is sampled in parallel so activation time counts toward the window.
    /// A newer receipt supersedes an older one, so each receipt returns at most once.
    func handle(activate: @escaping @MainActor () async -> Bool, isReady: @escaping @MainActor () -> Bool,
                onFallback: @escaping @MainActor () -> Void) {
        task?.cancel()
        let receipt = Self.currentHost()
        let start = ContinuousClock.now
        task = Task { @MainActor in
            let sampler = Task { @MainActor in await Self.resolve(receipt: receipt, start: start) }
            guard await activate(), await Self.waitUntilActive(start: start), !Task.isCancelled else {
                sampler.cancel(); return
            }
            let target = await sampler.value
            // Readiness and activity can change while sampling; nothing below may await.
            guard !Task.isCancelled, isReady(), UIApplication.shared.applicationState == .active else { return }
            let opened = target.map(Self.open) ?? false
            let elapsed = (ContinuousClock.now - start) / .seconds(1)
            Self.log.info("host return found=\(target != nil) opened=\(opened) elapsed=\(elapsed, format: .fixed(precision: 2))s")
            if !opened { onFallback() }
        }
    }

    /// The URL can arrive while still `.background` or `.inactive` (before the foreground transition finishes), so both are waited out; only the resolver window or cancellation ends it.
    private static func waitUntilActive(start: ContinuousClock.Instant) async -> Bool {
        while !Task.isCancelled {
            if UIApplication.shared.applicationState == .active { return true }
            if (ContinuousClock.now - start) / .seconds(1) >= HostReturnResolver.timeout { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private static func resolve(receipt: String?, start: ContinuousClock.Instant) async -> String? {
        let own = Bundle.main.bundleIdentifier ?? ""
        var resolver = HostReturnResolver(ownBundleIDs: [own, own + ".keyboard"], receipt: receipt)
        while !Task.isCancelled {
            let elapsed = (ContinuousClock.now - start) / .seconds(1)
            switch resolver.offer(currentHost(), at: elapsed) {
            case .target(let id): return id
            case .giveUp: return nil
            case .pending: try? await Task.sleep(for: .milliseconds(50))
            }
        }
        return nil
    }

    /// `_UIRemoteKeyboards.sharedRemoteKeyboards.currentState.sourceBundleIdentifier`
    private static func currentHost() -> String? {
        guard let keyboards = object(of: NSClassFromString("_UIRemoteKeyboards") as AnyObject?, "sharedRemoteKeyboards"),
              let state = object(of: keyboards, "currentState") else { return nil }
        return object(of: state, "sourceBundleIdentifier") as? String
    }

    private static func object(of target: AnyObject?, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard let target = target as? NSObject, target.responds(to: selector) else { return nil }
        return target.perform(selector)?.takeUnretainedValue()
    }

    /// `LSApplicationWorkspace.defaultWorkspace.openApplicationWithBundleID:`; returns whether the system accepted it.
    private static func open(_ bundleID: String) -> Bool {
        let selector = NSSelectorFromString("openApplicationWithBundleID:")
        guard let workspace = object(of: NSClassFromString("LSApplicationWorkspace") as AnyObject?, "defaultWorkspace") as? NSObject,
              workspace.responds(to: selector) else { return false }
        typealias Open = @convention(c) (AnyObject, Selector, NSString) -> Bool
        let call = unsafeBitCast(workspace.method(for: selector), to: Open.self)
        return call(workspace, selector, bundleID as NSString)
    }
}
