import Foundation

/// Decides whether a dictated result needs a separating space from the text already before the cursor.
/// Conservative: a space is added only when both boundary characters clearly call for one.
public enum InsertionSpacing {
    /// `before` is the document context before the cursor; `nil` means unknown, so nothing is guessed.
    public static func text(_ text: String, before: String?, replacingSelection: Bool) -> String {
        guard !replacingSelection, let previous = before?.last, let first = text.first,
              endsWord(previous), startsWord(first) else { return text }
        return " " + text
    }
    private static func endsWord(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, !unspaced(scalar) else { return false }
        if character.isLetter || character.isNumber { return true }
        switch scalar.properties.generalCategory {
        case .closePunctuation, .finalPunctuation: return true
        default: return ".,;:!?…%".contains(character)
        }
    }
    private static func startsWord(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, !unspaced(scalar) else { return false }
        if character.isLetter || character.isNumber { return true }
        switch scalar.properties.generalCategory {
        case .openPunctuation, .initialPunctuation: return true
        default: return false
        }
    }
    /// Scripts written without spaces between words (Han, kana, Thai, Lao, Khmer, Myanmar) and CJK punctuation.
    private static func unspaced(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF, 0x3000...0x30FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x3FFFF: return true
        default: return false
        }
    }
}
