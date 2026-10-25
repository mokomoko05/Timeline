import Foundation
import XCTest

/// 测试用的偏好设置：只放在内存里。`UserDefaults(suiteName:)` 即使测完 removePersistentDomain，
/// 系统的 cfprefsd 之后还会在 ~/Library/Preferences 写回一个空 plist，跑一次测试就留下几十个文件。
/// 便捷方法（bool/integer/string/array…）在 Foundation 里都经过 object(forKey:) / set(_:forKey:)，只重写这几个就够。
final class InMemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]

    init() { super.init(suiteName: nil)! }

    override func object(forKey defaultName: String) -> Any? { values[defaultName] ?? registered[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) {
        if let value { values[defaultName] = value } else { values.removeValue(forKey: defaultName) }
    }
    override func removeObject(forKey defaultName: String) { values.removeValue(forKey: defaultName) }
    override func register(defaults registrationDictionary: [String: Any]) {
        registered.merge(registrationDictionary) { _, new in new }
    }
    override func dictionaryRepresentation() -> [String: Any] { registered.merging(values) { _, value in value } }
    override func synchronize() -> Bool { true }
    override func removePersistentDomain(forName domainName: String) { values.removeAll() }
}

final class InMemoryDefaultsTests: XCTestCase {
    func testTypedAccessorsRoundTripWithoutTouchingDisk() {
        let defaults = InMemoryDefaults()
        let key = { (name: String) in "in-memory-defaults-test-" + name }
        defaults.set(true, forKey: key("flag"))
        defaults.set(3, forKey: key("count"))
        defaults.set(1.5, forKey: key("scale"))
        defaults.set("text", forKey: key("name"))
        defaults.set(["a", "b"], forKey: key("list"))
        XCTAssertTrue(defaults.bool(forKey: key("flag")))
        XCTAssertEqual(defaults.integer(forKey: key("count")), 3)
        XCTAssertEqual(defaults.double(forKey: key("scale")), 1.5)
        XCTAssertEqual(defaults.string(forKey: key("name")), "text")
        XCTAssertEqual(defaults.stringArray(forKey: key("list")), ["a", "b"])
        // 一个都没写进真正的偏好设置。
        for name in ["flag", "count", "scale", "name", "list"] {
            XCTAssertNil(UserDefaults.standard.object(forKey: key(name)), name)
        }
        defaults.removeObject(forKey: key("flag"))
        XCTAssertNil(defaults.object(forKey: key("flag")))
        defaults.register(defaults: [key("fallback"): 7])
        XCTAssertEqual(defaults.integer(forKey: key("fallback")), 7)
        XCTAssertNil(UserDefaults.standard.object(forKey: key("fallback")))
    }
}
