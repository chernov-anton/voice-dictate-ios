import XCTest
@testable import DictationShared
final class InsertionSpacingTests: XCTestCase {
    private func joined(_ text: String, after before: String?, selection: Bool = false) -> String {
        InsertionSpacing.text(text, before: before, replacingSelection: selection)
    }
    func testSeparatesConsecutiveRecordings() {
        XCTAssertEqual(joined("Second one.", after: "First one."), " Second one.")
        XCTAssertEqual(joined("next", after: "word"), " next")
        XCTAssertEqual(joined("и ещё", after: "Привет,"), " и ещё")
        XCTAssertEqual(joined("(aside)", after: "note"), " (aside)")
        XCTAssertEqual(joined("“Quote”", after: "said:"), " “Quote”")
        XCTAssertEqual(joined("42", after: "(done)"), " 42")
    }
    func testKeepsExistingBoundaryAndEmptyOrUnknownContext() {
        XCTAssertEqual(joined("Next", after: "Done. "), "Next")
        XCTAssertEqual(joined("Next", after: "Line\n"), "Next")
        XCTAssertEqual(joined("Next", after: "Tab\t"), "Next")
        XCTAssertEqual(joined("Next", after: ""), "Next")
        XCTAssertEqual(joined("Next", after: nil), "Next")
        XCTAssertEqual(joined(" Next", after: "Done."), " Next")
        XCTAssertEqual(joined("", after: "Done."), "")
    }
    func testNoSpaceBeforeClosingPunctuationOrAfterOpeningOrAmbiguousContext() {
        XCTAssertEqual(joined(", and more", after: "word"), ", and more")
        XCTAssertEqual(joined(".", after: "word"), ".")
        XCTAssertEqual(joined(") end", after: "word"), ") end")
        XCTAssertEqual(joined("inside", after: "("), "inside")
        XCTAssertEqual(joined("inside", after: "“"), "inside")
        XCTAssertEqual(joined("path", after: "a/"), "path")
        XCTAssertEqual(joined("name", after: "@"), "name")
        XCTAssertEqual(joined("quoted", after: "say \""), "quoted")
        XCTAssertEqual(joined("dash", after: "well-"), "dash")
    }
    func testSelectionReplacementAndUnspacedScriptsAreLeftAlone() {
        XCTAssertEqual(joined("replacement", after: "word", selection: true), "replacement")
        XCTAssertEqual(joined("世界", after: "你好"), "世界")
        XCTAssertEqual(joined("hello", after: "你好。"), "hello")
        XCTAssertEqual(joined("ありがとう", after: "word"), "ありがとう")
    }
}
