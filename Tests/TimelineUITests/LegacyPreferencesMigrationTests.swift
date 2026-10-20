import Foundation
import XCTest
@testable import Timeline

final class LegacyPreferencesMigrationTests: XCTestCase {
    func testPreferencesAndWindowNamesMigrateOnceAndRespectNewSettings() throws {
        let domain = "timeline-migration-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(1.2, forKey: "uiScale")
        let legacy: [String: Any] = ["uiScale": 1.5, "focusDefaultMinutes": 40,
                                    "NSWindow Frame DayleafNotesWindow": "frame", "appLanguage": "english"]
        LegacyPreferencesMigration.copy(legacy, into: defaults)
        XCTAssertEqual(defaults.double(forKey: "uiScale"), 1.2)
        XCTAssertEqual(defaults.integer(forKey: "focusDefaultMinutes"), 40)
        XCTAssertEqual(defaults.string(forKey: "NSWindow Frame TimelineNotesWindow"), "frame")
        XCTAssertNil(defaults.object(forKey: "NSWindow Frame DayleafNotesWindow"))
        defaults.set(30, forKey: "focusDefaultMinutes")
        LegacyPreferencesMigration.copy(legacy, into: defaults)
        XCTAssertEqual(defaults.integer(forKey: "focusDefaultMinutes"), 30)
    }
}
