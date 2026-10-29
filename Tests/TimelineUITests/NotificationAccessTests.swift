import AppKit
import SwiftUI
import UserNotifications
import XCTest
@testable import Timeline

@MainActor
final class NotificationAccessTests: XCTestCase {
    func testFirstUseRequestsPermissionWithoutOpeningSystemSettings() async {
        var status = UNAuthorizationStatus.notDetermined
        var requests = 0
        var settingsOpened = 0
        let access = NotificationAccess(readStatus: { status }, request: {
            requests += 1
            status = .authorized
            return true
        }, openSettings: { settingsOpened += 1 })
        await access.reload()
        XCTAssertEqual(access.actionTitle, "启用通知")
        XCTAssertFalse(access.isAllowed)
        await access.configure()
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(settingsOpened, 0)
        XCTAssertTrue(access.isAllowed)
        XCTAssertEqual(access.actionTitle, "通知设置")
        XCTAssertFalse(access.isRequesting)
    }

    func testDeniedPermissionOpensSettingsWithoutRequestingAgain() async {
        var requests = 0
        var settingsOpened = 0
        let access = NotificationAccess(readStatus: { .denied }, request: {
            requests += 1
            return false
        }, openSettings: { settingsOpened += 1 })
        let granted = await access.requestPermission()
        XCTAssertFalse(granted)
        await access.configure()
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(settingsOpened, 1)
        XCTAssertFalse(access.isAllowed)
    }

    func testDenialAndLaterSystemChangeAreReflected() async {
        var status = UNAuthorizationStatus.notDetermined
        let access = NotificationAccess(readStatus: { status }, request: {
            status = .denied
            return false
        }, openSettings: {})
        let granted = await access.requestPermission()
        XCTAssertFalse(granted)
        XCTAssertEqual(access.authorization, .denied)
        XCTAssertEqual(access.actionTitle, "通知设置")
        status = .authorized
        await access.reload()
        XCTAssertTrue(access.isAllowed)
        status = .denied
        await access.reload()
        XCTAssertFalse(access.isAllowed)
    }

    func testRequestFailureOffersRetryAndShowsError() async {
        let access = NotificationAccess(readStatus: { .notDetermined }, request: {
            throw NSError(domain: "NotificationTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Service unavailable"])
        }, openSettings: {})
        let granted = await access.requestPermission()
        XCTAssertFalse(granted)
        XCTAssertTrue(access.error.contains("Service unavailable"))
        XCTAssertEqual(access.actionTitle, "启用通知")
        XCTAssertFalse(access.isRequesting)
    }

    func testNotificationSettingsRenderForEveryAuthorizationState() async throws {
        for status in [UNAuthorizationStatus.notDetermined, .denied, .authorized] {
            let access = NotificationAccess(readStatus: { status }, request: { false }, openSettings: {})
            await access.reload()
            let host = NSHostingView(rootView: LocalizedRoot {
                NotificationSettingsView(access: access, refreshReminders: {}).padding(16).frame(width: 460)
            })
            let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 140), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.width, 461)
            XCTAssertGreaterThan(host.fittingSize.height, 40)
            XCTAssertLessThan(host.fittingSize.height, 160)
        }
    }
}
