# Timeline

A native macOS + iPhone app for tasks, focus sessions, notes and a daily journal. The Mac app lives in the background and opens panels from global hotkeys or the menu bar. No account and no server: data is a JSON file on disk, and devices sync through a folder in iCloud Drive.

<img src="docs/screenshots/main.png" width="720" alt="Main window: task timeline and month calendar">

## Features

### Mac

| | |
| --- | --- |
| **Timeline + calendar** (`⌃⌥D`) | Tasks on a vertical timeline with a "now" marker; a month calendar shows per-day progress and focus time. Drag a task's dot to reorder it, or drop it on another date to reschedule it. Single-key actions on the selected task (`Space` done, `D` date, `M`/`⇧M` shift a day, `F` focus, `?` help). |
| **Quick capture** (`⌃⌥L`) | Add a task or a journal entry from any app. `@` links a task, `#` adds a tag, `⌘V` pastes images; text in images is recognized (Vision) and searchable. |
| **Focus** (`⌃⌥F`) | Pick a task, set a goal and length. While running, the panel shrinks to a translucent capsule docked to the screen edge; the session ends with a reflection written to the journal. |
| **Notes & journal** (`⌃⌥N`) | One notebook per task and per tag (grouped by task or by date), plus a day-by-day journal with a rhythm bar. Entries are Markdown with LaTeX math, highlighted code blocks with a copy button, and foldable headings. Click any entry to edit it in place, WYSIWYG. |
| **Boards** (`⌃⌥M`) | A Markdown page per task or tag, with live-rendered checklists, folds and code. |
| **Terminal** (`⌃Tab`) | Built-in terminal with tabs and splits. |
| **Search** | One panel across tasks, boards, logs and text in images. |

<p>
<img src="docs/screenshots/journal.png" width="49%" alt="Journal with a focus session and a highlighted code block">
<img src="docs/screenshots/notes.png" width="49%" alt="Task notebook with display math">
</p>
<p>
<img src="docs/screenshots/notebook.png" width="49%" alt="Tag notebook grouped into chapters">
<img src="docs/screenshots/search.png" width="49%" alt="Global search">
</p>
<p>
<img src="docs/screenshots/capture.png" width="300" alt="Quick capture">
<img src="docs/screenshots/focus.png" width="300" alt="Focus capsule and panel">
<img src="docs/screenshots/focus-picker.png" width="220" alt="Focus task picker">
</p>

### iPhone

Tasks, journal, notebooks, boards and search over the same data. It adds task reminders, a focus timer, Spotlight indexing, and a composer with `@`/`#` pickers, image paste and the camera. Markdown, math and code render natively, and logs and boards are edited with the same editor as on the Mac.

<img src="docs/screenshots/ios.png" width="100%" alt="iPhone: tasks, journal, task notes, board">

## Architecture

```
Sources/
  TimelineCore/    Data layer shared by Mac and iPhone (no UI): journal model, tasks, boards,
                   tags, quick-add parsing, Markdown/math scanning, code highlighting, folder sync
  TimelineMath/    LaTeX typesetting on CoreText (vendored SwiftMath + Latin Modern fonts)
  Timeline/        macOS app: AppKit windows/panels hosting SwiftUI views
    EditorAssets/  Bundled CodeMirror editor (built from Editor/)
Editor/            CodeMirror 6 + KaTeX source, bundled with esbuild into one editor.js
iOS/               SwiftUI iPhone app (Xcode project) using TimelineCore, TimelineMath, EditorAssets
Tests/             TimelineCoreTests (model) and TimelineUITests (views, rendered offscreen)
scripts/           build / install / screenshot / test helpers
```

- **Storage.** `JournalStore` (TimelineCore) owns one `journal.json` in `~/Library/Application Support/Timeline`. It holds days with tasks and log entries, boards and tags, and is written atomically with a daily backup. Views observe the store; heavy derived data (per-day focus totals, note counts, laid-out text) is cached and invalidated on change.
- **Rendering.** Mac log text is a custom TextKit view (`InteractiveTaskText`) fed by `MarkdownText` (swift-markdown → `NSAttributedString`). Math becomes `NSTextAttachment`s rendered by TimelineMath, and code blocks are colored by `CodeHighlight`. iOS has its own `RichText` canvas on the same pieces. No WebView is used for reading.
- **Editing.** Boards, plus logs and notes on click, open a CodeMirror 6 editor in a shared, preloaded `WKWebView` (one for boards, one for inline edits). It uses inline Markdown decorations and KaTeX math, and Swift talks to it over a small message bridge. The bundle is checked in, so building needs no Node.
- **Sync.** `FolderSync` writes `Timeline/devices/<device>.json` in iCloud Drive (only the device's own file) and merges the others field by field: last edit wins, deletions propagate, concurrent board edits keep both versions behind a conflict marker. Images go to `Timeline/images/`. No iCloud entitlement is needed, so a free Apple ID can sign the iPhone build. See [iOS/README.md](iOS/README.md).
- **Mac shell.** Floating `NSPanel`s per feature, global hotkeys (Carbon), a menu-bar item, login item, SwiftTerm for the terminal, and Vision OCR for pasted images. UI strings use Chinese source keys, with English in `Resources/en.lproj`.

## Build and run

Requirements: macOS 13+, Xcode (Swift 5.9+); iPhone app targets iOS 17.

```sh
swift build                      # Mac app
bash scripts/install.sh          # build, install to ~/Applications and launch (keeps data)
bash scripts/install-ios.sh      # sign with a free Apple ID and install on a paired iPhone
bash scripts/install-ios.sh --schedule   # re-install automatically before the 7-day signature expires
```

Board editor: after changing `Editor/src`, run `cd Editor && npm ci && npm run build` (writes `Sources/Timeline/EditorAssets/editor.js`).

## Testing

```sh
swift test --filter TimelineCoreTests          # model, sync, parsing
swift test --filter InlineMarkdownEditorTests  # any UI test class
```

- UI tests never show windows. `Headless` keeps every test window at alpha 0 and turns off animations, `QuietWindow` ignores the mouse, and `ZZNoVisibleWindowsTests` fails if anything reached the screen. Run `scripts/test-window-monitor.swift` alongside window-related tests to watch the window server.
- iPhone latency is measured on the simulator with `PerfProbe` (launch args `-perfProbe YES -perfActions YES`, `-perfTyping log|board|compose`, `-demoData YES`). It reports tap-to-next-frame time, per-keystroke latency and hitches.

## Screenshots

```sh
bash scripts/screenshots.sh       # Mac: renders views offscreen with sample data (English, dark)
bash scripts/screenshots-ios.sh   # iPhone: same sample data in the booted simulator
```

Images are written to `docs/screenshots/`.
