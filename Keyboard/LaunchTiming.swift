import Foundation

/// Records cold-launch milestones of the keyboard process in memory and appends them once,
/// off the main thread, to `Library/Caches/launch-timing.jsonl` in the extension's container.
/// Only the first appearance per process is recorded; later calls are a single Bool check.
/// Times are milliseconds since process start (sysctl), e.g. `"viewDidAppear":160.2`.
/// Read it with `devicectl device copy from --domain-type appDataContainer
/// --domain-identifier <keyboard bundle ID> --source Library/Caches/launch-timing.jsonl`.
enum LaunchTiming {
    private static var marks: [(String, Double)] = []
    private static var done = false

    /// Keeps the first occurrence of each name (e.g. the first layout pass).
    static func mark(_ name: String) {
        guard !done, !marks.contains(where: { $0.0 == name }) else { return }
        marks.append((name, CFAbsoluteTimeGetCurrent()))
    }

    /// Call on the main-loop turn after viewDidAppear (UI committed); flushes and stops recording.
    static func finish() {
        guard !done else { return }
        mark("appearIdle"); done = true
        let recorded = marks; marks = []
        DispatchQueue.global(qos: .utility).async { write(recorded) }
    }

    private static func processStart() -> Double? {
        var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Double(start.tv_sec) + Double(start.tv_usec) / 1e6 - kCFAbsoluteTimeIntervalSince1970
    }

    private static func write(_ recorded: [(String, Double)]) {
        let origin = processStart() ?? recorded.first?.1 ?? 0
        var line = "{\"pid\":\(getpid()),\"at\":\(String(format: "%.3f", origin + kCFAbsoluteTimeIntervalSince1970))"
        for (name, time) in recorded { line += ",\"\(name)\":\(String(format: "%.1f", (time - origin) * 1000))" }
        line += "}\n"
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let url = caches.appendingPathComponent("launch-timing.jsonl")
        // Start over past 64 KB (~250 launches) so the log stays bounded.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size < 64 * 1024, let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
