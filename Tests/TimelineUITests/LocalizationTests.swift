import Foundation
import XCTest
@testable import Timeline

@MainActor
final class LocalizationTests: XCTestCase {
    private var resources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources")
    }

    func testEnglishResourcesCoverDynamicFocusAndWorkspaceText() throws {
        let original = UserDefaults.standard.object(forKey: Prefs.language)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: Prefs.language) }
            else { UserDefaults.standard.removeObject(forKey: Prefs.language) }
        }
        let bundle = try XCTUnwrap(Bundle(url: resources))
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: Prefs.language)
        let expected = [
            "暂停": "Pause",
            "继续": "Resume",
            "保存失败": "Save failed",
            "已用 %@": "Elapsed %@",
            "日期（%lld 天）": "Dates (%lld days)",
            "%lld 条日志": "%lld entries",
            "文字显示": "Text display",
            "行间距": "Line spacing",
            "写下今天的日志 · @ 待办 · # 标签 · ⌘V 贴图": "Write today's journal entry · @ task · # tag · ⌘V paste image",
        ]
        for (key, value) in expected {
            XCTAssertEqual(AppLocalized(key, bundle: bundle), value)
        }
        let elapsed = AppLocalized("已用 %@", bundle: bundle)
        XCTAssertEqual(String(format: elapsed, "00:12"), "Elapsed 00:12")
        UserDefaults.standard.set(AppLanguage.chinese.rawValue, forKey: Prefs.language)
        XCTAssertEqual(AppLocalized("暂停", bundle: bundle), "暂停")
        XCTAssertEqual(AppLanguage.current.locale.identifier, "zh-Hans")
    }

    func testEnglishResourceKeysAreUniqueAndFormatsRetainArguments() throws {
        let data = try Data(contentsOf: resources.appendingPathComponent("en.lproj/Localizable.strings"))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let lines = text.split(separator: "\n").filter { $0.hasPrefix("\"") }
        let keys = lines.compactMap { $0.components(separatedBy: "\" = ").first }
        XCTAssertEqual(keys.count, Set(keys).count)
        let values = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        for (key, value) in values {
            let pattern = #"%(?:\d+\$)?(?:lld|@)"#
            let expression = try NSRegularExpression(pattern: pattern)
            func arguments(_ text: String) -> [String] {
                expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
                    String((text as NSString).substring(with: match.range).suffix(1))
                }.sorted()
            }
            XCTAssertEqual(arguments(key), arguments(value), key)
        }
    }
}
