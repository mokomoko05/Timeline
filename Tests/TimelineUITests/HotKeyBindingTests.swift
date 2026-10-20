import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Timeline

final class HotKeyBindingTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "timeline-hotkey-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            // 清掉设置内容后系统仍会留下一个空的 plist 文件，一并删除，避免在 ~/Library/Preferences 里堆积。
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(suite).plist")
            try? FileManager.default.removeItem(at: file)
        }
        return defaults
    }

    func testDefaultsAndLabels() {
        XCTAssertEqual(HotKeyAction.main.defaultBinding.label, "⌃⌥D")
        XCTAssertEqual(HotKeyAction.shell.defaultBinding.label, "⌃⌥T")
        XCTAssertEqual(HotKeyBinding(keyCode: kVK_Space, modifiers: cmdKey | shiftKey).label, "⇧⌘空格")
        XCTAssertEqual(HotKeyBinding(keyCode: kVK_ANSI_Grave, modifiers: controlKey).label, "⌃`")
        XCTAssertEqual(Set(HotKeyAction.allCases.map(\.identifier)).count, HotKeyAction.allCases.count, "每个动作的注册标识唯一")
    }

    func testNotesShortcutIsAGlobalBindingDefaultingToControlN() {
        let defaults = defaults()
        XCTAssertEqual(HotKeyAction.notes.defaultBinding.label, "⌃N")
        XCTAssertEqual(Set(HotKeyAction.allCases), [.main, .shell, .log, .notes, .focusPanel], "笔记是全局快捷键之一；快速待办不再有快捷键；专注计时可以一键隐藏 / 显示")
        XCTAssertFalse(HotKeyAction.allCases.map(\.rawValue).contains("todo"))
        let custom = HotKeyBinding(keyCode: kVK_ANSI_K, modifiers: cmdKey | optionKey)
        HotKeyStore.save(custom, for: .notes, defaults: defaults)
        XCTAssertEqual(HotKeyStore.binding(for: .notes, defaults: defaults), custom)
        XCTAssertEqual(HotKeyStore.conflict(of: custom, excluding: .log, defaults: defaults), .notes, "和其他动作互相检查冲突")
        HotKeyStore.save(nil, for: .notes, defaults: defaults)
        XCTAssertEqual(HotKeyStore.binding(for: .notes, defaults: defaults).label, "⌃N", "恢复默认")
    }

    func testMenuEquivalentFollowsTheBinding() {
        var equivalent = HotKeyAction.notes.defaultBinding.menuEquivalent
        XCTAssertEqual(equivalent.key, "n")
        XCTAssertEqual(equivalent.mask, [.control])
        equivalent = HotKeyBinding(keyCode: kVK_ANSI_K, modifiers: cmdKey | shiftKey).menuEquivalent
        XCTAssertEqual(equivalent.key, "k")
        XCTAssertEqual(equivalent.mask, [.command, .shift])
        XCTAssertEqual(HotKeyBinding(keyCode: kVK_Space, modifiers: controlKey).menuEquivalent.key, " ")
        XCTAssertEqual(HotKeyBinding(keyCode: kVK_F5, modifiers: controlKey).menuEquivalent.key, String(UnicodeScalar(UInt32(NSF5FunctionKey))!))
        XCTAssertEqual(HotKeyBinding(keyCode: kVK_UpArrow, modifiers: controlKey).menuEquivalent.key, String(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!))
    }

    func testSavedBindingOverridesDefaultAndResetRestoresIt() {
        let defaults = defaults()
        XCTAssertEqual(HotKeyStore.binding(for: .shell, defaults: defaults), HotKeyAction.shell.defaultBinding)
        let custom = HotKeyBinding(keyCode: kVK_ANSI_Grave, modifiers: controlKey)
        HotKeyStore.save(custom, for: .shell, defaults: defaults)
        XCTAssertEqual(HotKeyStore.binding(for: .shell, defaults: defaults), custom)
        HotKeyStore.save(nil, for: .shell, defaults: defaults)
        XCTAssertEqual(HotKeyStore.binding(for: .shell, defaults: defaults), HotKeyAction.shell.defaultBinding)
    }

    func testBindingsWithoutModifiersAreRejectedAndConflictsDetected() {
        let defaults = defaults()
        XCTAssertFalse(HotKeyBinding(keyCode: kVK_ANSI_A, modifiers: 0).isValid, "没有修饰键会吞掉正常打字")
        XCTAssertFalse(HotKeyBinding(keyCode: kVK_ANSI_A, modifiers: shiftKey).isValid, "只有 Shift 不够")
        XCTAssertTrue(HotKeyBinding(keyCode: kVK_ANSI_A, modifiers: cmdKey).isValid)
        // 把「快速写日志」改成 ⌃⌥G，再让「内置终端」也想用 ⌃⌥G：应报告与日志冲突。
        let taken = HotKeyBinding(keyCode: kVK_ANSI_G, modifiers: HotKeyBinding.controlOption)
        HotKeyStore.save(taken, for: .log, defaults: defaults)
        XCTAssertEqual(HotKeyStore.conflict(of: taken, excluding: .shell, defaults: defaults), .log)
        XCTAssertNil(HotKeyStore.conflict(of: taken, excluding: .log, defaults: defaults), "和自己不算冲突")
        XCTAssertEqual(HotKeyStore.conflict(of: HotKeyAction.main.defaultBinding, excluding: .shell, defaults: defaults), .main, "默认组合也参与冲突检查")
    }

    func testCorruptOrInvalidStoredValueFallsBackToDefault() {
        let defaults = defaults()
        defaults.set(Data("garbage".utf8), forKey: HotKeyAction.log.storageKey)
        XCTAssertEqual(HotKeyStore.binding(for: .log, defaults: defaults), HotKeyAction.log.defaultBinding)
        HotKeyStore.save(HotKeyBinding(keyCode: kVK_ANSI_L, modifiers: 0), for: .log, defaults: defaults)
        XCTAssertEqual(HotKeyStore.binding(for: .log, defaults: defaults), HotKeyAction.log.defaultBinding)
    }

    func testCarbonModifierConversion() {
        XCTAssertEqual(HotKeyBinding.carbonModifiers([.control, .option]), HotKeyBinding.controlOption)
        XCTAssertEqual(HotKeyBinding.carbonModifiers([.command, .shift]), cmdKey | shiftKey)
    }

    /// 测试里创建的窗口一直保留到进程结束：AppKit 窗口在测试结束时释放，会在之后的无关测试里偶发崩溃。
    @MainActor private static var keepAlive: [NSWindow] = []

    @MainActor
    func testFadeIncludesAttachedSheetsSoTheyDisappearTogether() {
        let parent = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let sheet = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        sheet.isReleasedWhenClosed = false
        Self.keepAlive += [parent, sheet]
        parent.makeKeyAndOrderFront(nil)
        parent.beginSheet(sheet)
        XCTAssertTrue(WindowFade.family(of: parent).contains(sheet), "笔记等 sheet 和主窗口一起渐变")
        sheet.alphaValue = 0.3
        WindowFade.reset(parent)
        XCTAssertEqual(sheet.alphaValue, 1)
    }
}
