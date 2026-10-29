import AppKit
import XCTest
import TimelineCore
@testable import Timeline

final class LogImageToolsTests: XCTestCase {
    private func pngData(width: Int, height: Int, draw: ((CGContext) -> Void)? = nil) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        draw?(context.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    func testOriginalImageBytesAndFullResolutionArePreserved() throws {
        let original = pngData(width: 4000, height: 1000)
        let large = try XCTUnwrap(ImageTools.process(original))
        XCTAssertEqual(large.data, original)
        let image = try XCTUnwrap(NSBitmapImageRep(data: large.data))
        XCTAssertEqual(max(image.pixelsWide, image.pixelsHigh), 4000)
        let small = try XCTUnwrap(ImageTools.process(pngData(width: 300, height: 200)))
        XCTAssertEqual(NSBitmapImageRep(data: small.data)?.pixelsWide, 300)
        XCTAssertEqual(small.fileExtension, "png")
        XCTAssertNil(ImageTools.process(Data([1, 2, 3])))
    }

    @MainActor
    func testOriginalImportsDeduplicateWithoutChangingBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let data = pngData(width: 4000, height: 1000)
        let first = try await store.storeOriginalImage(data)
        let second = try await store.storeOriginalImage(data)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: store.imageURL(first)), data)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.imagesDirectory.path).count, 1)
        do { _ = try await store.storeOriginalImage(Data([0])); XCTFail("Invalid image must be rejected") } catch { }
    }

    func testPasteboardImagesIgnoreMixedTextContent() {
        let board = NSPasteboard(name: NSPasteboard.Name("timeline-test-\(UUID().uuidString)"))
        board.clearContents()
        board.setData(pngData(width: 20, height: 20), forType: .png)
        XCTAssertTrue(ImageTools.hasImage(board))
        XCTAssertEqual(ImageTools.images(from: board).count, 1)
        board.clearContents()
        board.setString("来自表格的文字", forType: .string)
        board.setData(pngData(width: 20, height: 20), forType: .png)
        XCTAssertFalse(ImageTools.hasImage(board), "同时带文字时按文字粘贴")
        XCTAssertTrue(ImageTools.images(from: board).isEmpty)
    }

    func testInputFieldUsesImageAwareFieldEditor() {
        let field = TaskTextField()
        XCTAssertTrue(field.cell is ImagePasteCell)
        XCTAssertTrue((field.cell as? NSTextFieldCell)?.fieldEditor(for: field) is ImagePasteFieldEditorView)
    }

    func testTextInImagesCanBeRecognizedLocally() throws {
        let data = pngData(width: 640, height: 160) { _ in
            let text = NSAttributedString(string: "Segmentation fault", attributes: [.font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.black])
            text.draw(at: NSPoint(x: 20, y: 40))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-\(UUID().uuidString).png")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(ImageTools.recognizeText(at: url).localizedCaseInsensitiveContains("fault"))
    }
}

final class ImageFitTests: XCTestCase {
    func testFittedSizeKeepsAspectRatioAndNeverCrops() {
        // 1600×800 像素（视网膜下 800×400）放进 360×190：按高度受限缩小。
        let wide = ImageTools.fittedSize(pixels: CGSize(width: 1600, height: 800), maxWidth: 360, maxHeight: 190)
        XCTAssertEqual(wide.width / wide.height, 2, accuracy: 0.02)
        XCTAssertLessThanOrEqual(wide.width, 360)
        XCTAssertLessThanOrEqual(wide.height, 190)
        // 很高的图受高度限制。
        let tall = ImageTools.fittedSize(pixels: CGSize(width: 600, height: 2000), maxWidth: 360, maxHeight: 190)
        XCTAssertEqual(tall.height, 190, accuracy: 1)
        XCTAssertEqual(tall.width / tall.height, 0.3, accuracy: 0.02)
        // 本来就小的图不放大。
        let small = ImageTools.fittedSize(pixels: CGSize(width: 200, height: 100), maxWidth: 360, maxHeight: 190)
        XCTAssertEqual(small, CGSize(width: 100, height: 50))
        XCTAssertEqual(ImageTools.fittedSize(pixels: .zero, maxWidth: 360, maxHeight: 190).height, 190)
    }
}
