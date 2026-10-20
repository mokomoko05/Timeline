import AppKit
import XCTest
@testable import Timeline

@MainActor
final class ShellEnvironmentTests: XCTestCase {
    func testUserShellConfigurationAndPathArePreserved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "export TIMELINE_SHELL_TEST=loaded\n".write(to: directory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let environment = ShellWindowController.shellEnvironment(base: ["ZDOTDIR": directory.path, "PATH": "/usr/bin:/bin:/custom/bin"])
        let variables = Dictionary(environment.compactMap { entry -> (String, String)? in
            guard let separator = entry.firstIndex(of: "=") else { return nil }
            return (String(entry[..<separator]), String(entry[entry.index(after: separator)...]))
        }, uniquingKeysWith: { _, latest in latest })
        XCTAssertEqual(variables["PATH"], "/usr/bin:/bin:/custom/bin")
        XCTAssertEqual(variables["ZDOTDIR"], directory.path)
        XCTAssertEqual(variables["TERM_PROGRAM"], "Timeline")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-i", "-c", "print -r -- $TIMELINE_SHELL_TEST; whence -w sched"]
        process.environment = variables
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(text.contains("loaded"), text)
        XCTAssertTrue(text.contains("sched: builtin"), text)
    }
}
