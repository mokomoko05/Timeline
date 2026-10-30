#!/usr/bin/env python3
"""Use an isolated folder to exercise the current core against an actual older revision."""
import pathlib
import shutil
import subprocess
import tempfile
import sys

repo = pathlib.Path(__file__).resolve().parent.parent
revision = sys.argv[1] if len(sys.argv) > 1 else "7614602"
harness = r'''
import Foundation
import TimelineCore

@main struct CompatibilityHarness {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        let root = URL(fileURLWithPath: args[1]), stage = args[2]
        let old = stage.hasPrefix("old")
        let store = JournalStore(directory: root.appendingPathComponent(old ? "phone" : "mac"))
        precondition(!store.isReadOnly, store.errorMessage ?? "Read-only store")
        let sync = FolderSync(store: store, folder: root.appendingPathComponent("cloud"), deviceName: old ? "Old iPhone" : "New Mac")
        let date = JournalDates.date(for: "2026-10-30")!
        let original = Data((0..<100_000).map { UInt8($0 % 251) })
        switch stage {
        case "new-seed":
            let board = store.ensureBoard(for: .tag("Compatibility"))!
            store.setBoardMarkdown("From new Mac", for: board.id)
            store.addTodo("Mixed version task", on: date)
            let image = try store.storeImage(original, fileExtension: "png")
            _ = try store.quickLog("Original photo", images: [image], on: date)
            _ = try store.quickLog("Delete across versions", on: date)
            try await sync.sync()
        case "old-edit":
            try await sync.sync()
            let board = store.board(for: .tag("Compatibility"))!
            precondition(board.markdown == "From new Mac")
            try await store.prepareImageExport()
            let image = store.allLogs().first { $0.log.text == "Original photo" }!.log.images.first!
            let receivedImage = try Data(contentsOf: store.imagesDirectory.appendingPathComponent(image))
            precondition(receivedImage == original)
            store.setBoardMarkdown("From new Mac\nEdited by old iPhone", for: board.id)
            let task = store.tasks().first!
            store.toggleTodo(task.id, on: task.date)
            _ = try store.quickLog("From old iPhone", on: date)
            try await sync.sync()
        case "new-edit":
            try await sync.sync()
            precondition(store.board(for: .tag("Compatibility"))!.markdown.contains("Edited by old iPhone"))
            precondition(store.tasks().first!.task.completed)
            precondition(store.allLogs().contains { $0.log.text == "From old iPhone" })
            let log = store.allLogs().first { $0.log.text == "Delete across versions" }!
            store.deleteLog(log.id, on: log.date)
            let board = store.board(for: .tag("Compatibility"))!
            store.setBoardMarkdown(board.markdown + "\nNew Mac again", for: board.id)
            try await sync.sync()
            #if CURRENT
            let phone = sync.devices.first { $0.name == "Old iPhone" }!
            precondition(!phone.supportsRetirement)
            do { try await sync.retireDevice(phone.id); fatalError("Must reject retirement of an old phone") }
            catch FolderSync.SyncError.upgradeRequired { }
            #endif
        case "old-verify":
            try await sync.sync()
            precondition(!store.allLogs().contains { $0.log.text == "Delete across versions" })
            let board = store.board(for: .tag("Compatibility"))!
            precondition(board.markdown.hasSuffix("New Mac again"))
            store.setBoardMarkdown(board.markdown + "\nOld phone remains usable", for: board.id)
            try await sync.sync()
        case "new-verify":
            try await sync.sync()
            precondition(store.board(for: .tag("Compatibility"))!.markdown.hasSuffix("Old phone remains usable"))
            precondition(!store.allLogs().contains { $0.log.text == "Delete across versions" })
            #if CURRENT
            precondition(sync.fileErrors.isEmpty)
            #endif
        default: fatalError("Unknown stage")
        }
        print("MIXED_VERSION PASS \(stage)")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="TimelineMixedVersion-") as temporary:
    root = pathlib.Path(temporary)
    archive = root / "old-source.tar"
    with archive.open("wb") as output:
        subprocess.run(["git", "archive", revision, "Sources/TimelineCore"], cwd=repo, stdout=output, check=True)
    old = root / "old"
    old.mkdir()
    subprocess.run(["tar", "-xf", str(archive), "-C", str(old)], check=True)
    shutil.copytree(repo / "Sources/CSQLite", old / "Sources/CSQLite")
    current = root / "current"
    (current / "Sources").mkdir(parents=True)
    for name in ("TimelineCore", "CSQLite"):
        shutil.copytree(repo / "Sources" / name, current / "Sources" / name)
    for package, defines in ((old, "[]"), (current, '[.define("CURRENT")]')):
        (package / "Sources/Harness").mkdir()
        (package / "Sources/Harness/Harness.swift").write_text(harness)
        (package / "Package.swift").write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Compatibility", platforms: [.macOS(.v13)], targets: [
.systemLibrary(name: "CSQLite"), .target(name: "TimelineCore", dependencies: ["CSQLite"]),
.executableTarget(name: "Harness", dependencies: ["TimelineCore"], swiftSettings: ''' + defines + ''')])
''')
        subprocess.run(["swift", "build", "--package-path", str(package), "-c", "release"], check=True)
    for stage in ("new-seed", "old-edit", "new-edit", "old-verify", "new-verify"):
        package = old if stage.startswith("old") else current
        subprocess.run([str(package / ".build/release/Harness"), str(root / "data"), stage], check=True)
print(f"MIXED_VERSION all stages passed against {revision}; all test data removed")
