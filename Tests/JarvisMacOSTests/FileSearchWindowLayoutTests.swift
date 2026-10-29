import XCTest
@testable import JarvisMacOS

final class FileSearchWindowLayoutTests: XCTestCase {
    func testPreviewIsCenteredOnEachDisplaysVisibleFrame() {
        for visible in [CGRect(x: 0, y: 30, width: 1440, height: 850), CGRect(x: -1920, y: 160, width: 1920, height: 1030), CGRect(x: 1440, y: -900, width: 800, height: 600)] {
            let frame = FileSearchWindowLayout.centeredPreview(in: visible)
            XCTAssertEqual(frame.midX, visible.midX, accuracy: 0.1)
            XCTAssertEqual(frame.midY, visible.midY, accuracy: 0.1)
            XCTAssertTrue(visible.contains(frame))
            XCTAssertLessThanOrEqual(frame.width, visible.width - 48)
            XCTAssertLessThanOrEqual(frame.height, visible.height - 48)
        }
    }

    @MainActor
    func testDismissingPreviewKeepsSearchContextAndSelection() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("Preview fixture".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let item = FileSearchResult(url: url, name: "Preview fixture", size: 15, modified: .now, isDirectory: false)
        let controller = FileSearchController(engine: PreviewFixtureSearch(item: item), presentsUI: false)
        await controller.search(LocalSearchRequest(query: "Preview fixture"))
        XCTAssertTrue(controller.act(FileResultSelection(operation: .preview, index: 1)).success)
        XCTAssertNotNil(controller.preview)
        controller.dismissPreview()
        XCTAssertNil(controller.preview)
        XCTAssertEqual(controller.results, [item])
        XCTAssertEqual(controller.selectedID, item.id)
        XCTAssertTrue(controller.hasContext)
    }
}

@MainActor
private struct PreviewFixtureSearch: FileSearching {
    let item: FileSearchResult
    func search(_ request: LocalSearchRequest, roots: [URL]) async throws -> FileSearchSnapshot {
        FileSearchSnapshot(results: [item], limited: false, timedOut: false)
    }
}
