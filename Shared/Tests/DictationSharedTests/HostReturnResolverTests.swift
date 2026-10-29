import XCTest
@testable import DictationShared
final class HostReturnResolverTests: XCTestCase {
    private let own = ["com.example.app", "com.example.app.keyboard"]
    private func run(receipt: String?, _ samples: [(Double, String?)]) -> HostReturnResolver.Decision {
        var resolver = HostReturnResolver(ownBundleIDs: own, receipt: receipt)
        var last = HostReturnResolver.Decision.pending
        for (time, value) in samples {
            last = resolver.offer(value, at: time)
            if last != .pending { break }
        }
        return last
    }
    func testColdLaunchNilThenHost() {
        XCTAssertEqual(run(receipt: nil, [(0, nil), (0.5, nil), (1.0, "com.apple.mobilenotes")]), .target("com.apple.mobilenotes"))
    }
    func testWarmLaunchOwnIDThenHost() {
        XCTAssertEqual(run(receipt: "com.example.app", [(0, "com.example.app"), (0.5, "com.example.app"), (1.0, "com.apple.mobilenotes")]),
                       .target("com.apple.mobilenotes"))
    }
    func testStaleOtherHostThenRealHost() {
        XCTAssertEqual(run(receipt: "com.x.old", [(0, "com.x.old"), (0.5, "com.x.old"), (1.0, "com.y.real")]), .target("com.y.real"))
    }
    func testSameHostTwiceWaitsForGrace() {
        var resolver = HostReturnResolver(ownBundleIDs: own, receipt: "com.x.host")
        XCTAssertEqual(resolver.offer("com.x.host", at: 0), .pending)
        XCTAssertEqual(resolver.offer("com.x.host", at: 1.0), .pending)
        XCTAssertEqual(resolver.offer("com.x.host", at: 1.5), .target("com.x.host"))
    }
    func testNothingFoundGivesUp() {
        var resolver = HostReturnResolver(ownBundleIDs: own, receipt: nil)
        XCTAssertEqual(resolver.offer(nil, at: 2.9), .pending)
        XCTAssertEqual(resolver.offer(nil, at: 3.0), .giveUp)
        XCTAssertEqual(resolver.offer("com.x.late", at: 3.1), .giveUp)
    }
    func testOwnOnlyGivesUp() {
        XCTAssertEqual(run(receipt: "com.example.app", [(0, "com.example.app"), (2, "com.example.app"), (3, "com.example.app")]), .giveUp)
    }
    func testKeyboardAndOwnPrefixIgnored() {
        XCTAssertEqual(run(receipt: nil, [(0.5, "com.example.app.keyboard"), (1, "com.example.app.other"), (1.5, "com.x.host")]), .target("com.x.host"))
    }
    func testDecisionSticks() {
        var resolver = HostReturnResolver(ownBundleIDs: own, receipt: nil)
        XCTAssertEqual(resolver.offer("com.x.a", at: 1), .target("com.x.a"))
        XCTAssertEqual(resolver.offer("com.x.b", at: 1.1), .target("com.x.a"))
    }
}
