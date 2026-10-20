import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
import TimelineCore
@testable import TimelineKit

/// 测试数据：三个任务，跨两天的日志，带图片和 OCR 文字，一条专注记录。
@MainActor
struct Fixture {
    let directory: URL
    let store: JournalStore
    let day1: Date
    let day2: Date
    let paper: ScheduledTask
    let report: ScheduledTask

    static func make(testCase: XCTestCase, saved: Bool = true) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-" + UUID().uuidString)
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let calendar = JournalDates.calendar
        let day1 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!
        let day2 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8))!
        store.addTodo("读 [EuroSys 论文](https://example.com/paper)", on: day1)
        store.addTodo("写周报", on: day1)
        store.addTodo("买牛奶", on: day1)
        let paper = try XCTUnwrap(store.locate(number: 1))
        let report = try XCTUnwrap(store.locate(number: 2))
        func at(_ day: Date, _ hour: Int, _ minute: Int) -> Date { calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)! }
        _ = try store.quickLog("读完摘要，公式 3 看不懂", taskID: paper.id, on: day1, now: at(day1, 9, 5))
        _ = try store.quickLog("/block 图 4 的坐标轴没标单位", taskID: paper.id, on: day1, now: at(day1, 10, 30))
        _ = try store.quickLog("随手记一笔，和任务无关", on: day1, now: at(day1, 11, 0))
        let image = try store.storeImage(try pngData(width: 400, height: 200), fileExtension: "png")
        _ = try store.quickLog("截了张图 https://example.com/fig4", images: [image], taskID: paper.id, on: day2, now: at(day2, 8, 40))
        store.setImageText("Throughput (ops/s) latency", image: image)
        _ = try store.quickLog("/done 周报发出去了", taskID: report.id, on: day2, now: at(day2, 17, 20))
        _ = store.addFocusLog("▶ 开始专注", taskID: paper.id, now: at(day2, 9, 0))
        if saved { store.save() }
        return Fixture(directory: directory, store: store, day1: day1, day2: day2, paper: paper, report: report)
    }

    /// 只读打开同一个目录，和命令行读取的方式一致。
    func snapshot() -> JournalStore { JournalStore(directory: directory, readOnlySnapshot: true) }
}

func pngData(width: Int, height: Int) throws -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    return data as Data
}

/// 在 CLI 里跑一条命令并收集输出。
@MainActor
func runCLI(_ arguments: [String], directory: URL, tty: Bool = false, columns: Int? = nil, env: [String: String] = [:],
            stdin: String = "", launch: (() -> Void)? = nil, now: Date? = nil) -> (code: Int32, out: String, err: String) {
    var out = "", err = ""
    var environment = CLIEnvironment(arguments: arguments + ["--dir", directory.path], env: env, stdoutIsTTY: tty, stdinIsTTY: tty, columns: columns,
                                     now: now ?? Date(), out: { out += $0 }, err: { err += $0 }, readStdin: { stdin }, launchApp: launch)
    environment.currentDirectory = directory.path
    let code = CLI.run(environment)
    return (code, out, err)
}
