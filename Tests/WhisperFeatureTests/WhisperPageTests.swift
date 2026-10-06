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

    func testWaitAfterLoadReturnsAtOnce() async {
        let page = blankPage()
        page.webView(page.webView, didFinish: nil)
        await page.waitUntilLoaded(timeout: .seconds(60))
    }
}

@MainActor private final class Released {
    var names: [String] = []
}
