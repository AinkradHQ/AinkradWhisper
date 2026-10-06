import JavaScriptCore
import XCTest

@testable import WhisperFeature

/// Every page script compiles as the async function body `callAsyncJavaScript`
/// wraps it in, so the shared prelude never collides with a script's own names.
final class PageScriptTests: XCTestCase {
    private func assertCompiles(_ body: String?, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let body else { return }
        let context = JSContext()!
        context.evaluateScript("(async function (limit, chat, query, text, days) {\n\(body)\n})")
        XCTAssertNil(context.exception, "\(name): \(context.exception?.toString() ?? "")", file: file, line: line)
    }

    func testServiceScriptsCompile() {
        let operations: [ServiceScripts.Operation] = [.listChats, .readMessages, .search, .send]
        for service in Service.allCases {
            for operation in operations {
                assertCompiles(ServiceScripts.script(operation, for: service), "\(service) \(operation)")
            }
            assertCompiles(ServiceScripts.openFromNotification(service), "\(service) open")
            assertCompiles(CalendarScripts.script(for: service), "\(service) calendar")
        }
    }
}
