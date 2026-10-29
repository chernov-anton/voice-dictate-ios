import XCTest
@testable import DictationShared
final class AvailabilitySettingTests: XCTestCase {
    var defaults: UserDefaults!
    var suite: String!
    override func setUp() { suite = "AvailabilitySettingTests-\(UUID())"; defaults = UserDefaults(suiteName: suite) }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testDefaultsToFiveMinutesWhenNothingSaved() {
        XCTAssertEqual(AvailabilitySetting.load(from: defaults), 300)
    }
    func testSavedChoiceRoundTripsThroughFreshDefaults() {
        AvailabilitySetting.save(3600, to: defaults)
        // A new instance on the same suite stands in for a relaunched app.
        XCTAssertEqual(AvailabilitySetting.load(from: UserDefaults(suiteName: suite)!), 3600)
        AvailabilitySetting.save(900, to: defaults)
        XCTAssertEqual(AvailabilitySetting.load(from: UserDefaults(suiteName: suite)!), 900)
    }
    func testUnsupportedValuesAreIgnored() {
        AvailabilitySetting.save(900, to: defaults)
        AvailabilitySetting.save(42, to: defaults)
        XCTAssertEqual(AvailabilitySetting.load(from: defaults), 900)
        defaults.set(-1.0, forKey: AvailabilitySetting.key)
        XCTAssertEqual(AvailabilitySetting.load(from: defaults), 300)
    }
}
