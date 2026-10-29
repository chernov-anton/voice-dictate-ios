import Foundation

public struct InsertionGate {
    private var pending: (session: UUID, utterance: UUID, document: UUID)?
    public init() {}
    public mutating func begin(sessionID: UUID, utteranceID: UUID, documentID: UUID) {
        pending = (sessionID, utteranceID, documentID)
    }
    public mutating func cancel() { pending = nil }
    public func permits(sessionID: UUID, result: DictationResult, documentID: UUID, receipt: InsertionReceipt?) -> Bool {
        guard let pending, pending.session == sessionID,
              pending.utterance == result.utteranceID, pending.document == documentID else { return false }
        // A matching attempted receipt is ambiguous even if written by another controller.
        return !(receipt?.sessionID == sessionID && receipt?.resultID == result.id)
    }
}
