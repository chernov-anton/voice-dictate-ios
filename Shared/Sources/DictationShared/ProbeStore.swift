import Foundation

public struct ProbeStore: Sendable {
    private let directory: URL
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    public func writeSnapshot(_ value: ProbeSnapshot) throws { try write(value, name: "probe-state.json") }
    public func readSnapshot() throws -> ProbeSnapshot? { try read(name: "probe-state.json") }
    public func writePing(_ value: ProbePing) throws { try write(value, name: "probe-ping.json") }
    public func readPing() throws -> ProbePing? { try read(name: "probe-ping.json") }
    public func writeLease(_ value: HoldLease) throws { try write(value, name: "hold-lease.json") }
    public func readLease() throws -> HoldLease? { try read(name: "hold-lease.json") }
    public func writeCommand(_ value: Command) throws { try write(value, name: "command.json") }
    public func readCommand() throws -> Command? { try read(name: "command.json") }
    public func writeSession(_ value: SessionSnapshot) throws { try write(value, name: "session.json") }
    public func readSession() throws -> SessionSnapshot? { try read(name: "session.json") }
    public func writeReceipt(_ value: InsertionReceipt) throws { try write(value, name: "insertion.json") }
    public func readReceipt() throws -> InsertionReceipt? { try read(name: "insertion.json") }
    /// Keyboard → companion MediaRemote command and the companion's answer (see `MediaRemoteRequest`).
    public func writeMediaRequest(_ value: MediaRemoteRequest) throws { try write(value, name: "media-request.json") }
    public func readMediaRequest() throws -> MediaRemoteRequest? { try read(name: "media-request.json") }
    public func writeMediaReply(_ value: MediaRemoteReply) throws { try write(value, name: "media-reply.json") }
    public func readMediaReply() throws -> MediaRemoteReply? { try read(name: "media-reply.json") }
    private func write<T: Encodable>(_ value: T, name: String) throws {
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(name == "session.json" ? .completeFileProtectionUnlessOpen : .completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(name), options: options)
    }
    private func read<T: Decodable>(name: String) throws -> T? {
        do {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }
}
