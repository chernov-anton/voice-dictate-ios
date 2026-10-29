import Foundation

struct RecoveryRecord: Codable, Identifiable {
    var id: UUID
    var raw: String
    var text: String
    var status: String
    var date: Date
}
struct RecoveryStore {
    let directory: URL
    init() throws {
        directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true).appendingPathComponent("Dictation", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory, values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }
    func read() throws -> [RecoveryRecord] {
        let url = directory.appendingPathComponent("history.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([RecoveryRecord].self, from: Data(contentsOf: url))
    }
    func save(_ records: [RecoveryRecord]) throws {
        try JSONEncoder().encode(Array(records.prefix(10))).write(to: directory.appendingPathComponent("history.json"),
            options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
