import XCTest

@testable import WhisperFeature

/// A page with no URL never loads, so these never touch the network.
@MainActor
final class WhisperPageTests: XCTestCase {
    private func blankPage() -> WhisperPage { WhisperPage(account: Account(service: .custom, label: "Blank")) }

    func testTimeoutReleasesOnlyItsOwnWaiter() async throws {
        let page = blankPage()
        let released = Released()
        Task {
            await page.waitUntilLoaded(timeout: .milliseconds(50))
            released.names.append("early")
        }
        let late = Task {
            await page.waitUntilLoaded(timeout: .seconds(30))
            released.names.append("late")
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(released.names, ["early"], "the first timeout released a later waiter early")
        page.webView(page.webView, didFinish: nil)
        await late.value
        XCTAssertEqual(released.names, ["early", "late"])
    }

    func testLoadCancelsTheTimeouts() async throws {
        weak var freed: WhisperPage?
        do {
            let page = blankPage()
            freed = page
            let waiter = Task { await page.waitUntilLoaded(timeout: .seconds(60)) }
            try await Task.sleep(for: .milliseconds(50))
            page.webView(page.webView, didFinish: nil)
            await waiter.value
            page.close()
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(freed, "a finished load left its timeout task holding the page")
    }

    func testDownloadNameIsDeduplicatedAndStaysInTheFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = WhisperPage.downloadDestination(for: "report.pdf", in: folder)
        XCTAssertEqual(first.lastPathComponent, "report.pdf")
        try Data().write(to: first)
        try Data().write(to: folder.appendingPathComponent("report 2.pdf"))
        XCTAssertEqual(WhisperPage.downloadDestination(for: "report.pdf", in: folder).lastPathComponent, "report 3.pdf")
        try Data().write(to: folder.appendingPathComponent("notes"))
        XCTAssertEqual(WhisperPage.downloadDestination(for: "notes", in: folder).lastPathComponent, "notes 2")
        let escaped = WhisperPage.downloadDestination(for: "../../etc/passwd", in: folder)
        XCTAssertEqual(escaped.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
        XCTAssertEqual(WhisperPage.downloadDestination(for: "", in: folder).lastPathComponent, "download")
    }

    func testNotificationFieldsAreTruncated() {
        let long = String(repeating: "x", count: 1000)
        let note = WhisperPage.notification(from: [
            "kind": "notify", "id": long, "title": long, "body": long, "tag": long,
        ])
        XCTAssertEqual(note?.id.count, 40)
        XCTAssertEqual(note?.title.count, 200)
        XCTAssertEqual(note?.body.count, 500)
        XCTAssertEqual(note?.tag.count, 200)
        XCTAssertEqual(WhisperPage.notification(from: ["kind": "notify"])?.title, "")
        XCTAssertNil(WhisperPage.notification(from: ["kind": "other"]))
        XCTAssertNil(WhisperPage.notification(from: "notify"))
    }

    func testWaitAfterLoadReturnsAtOnce() async {
        let page = blankPage()
        page.webView(page.webView, didFinish: nil)
        await page.waitUntilLoaded(timeout: .seconds(60))
    }
}

@MainActor private final class Released {
    var names: [String] = []
}
