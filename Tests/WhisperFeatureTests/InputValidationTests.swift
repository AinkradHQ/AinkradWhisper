import XCTest

@testable import WhisperFeature

/// What the Settings draft and the assistant tools accept.
@MainActor
final class InputValidationTests: XCTestCase {
    func testDraftNeedsAnHTTPSURLOnlyForWebApps() {
        let draft = AccountDraft()
        XCTAssertNil(draft.problem, "Slack needs no URL")
        XCTAssertEqual(draft.account?.service, .slack)
        draft.service = .custom
        for bad in ["", "chat.example.com", "http://chat.example.com", "https://"] {
            draft.url = bad
            XCTAssertNotNil(draft.problem, bad)
            XCTAssertNil(draft.account, bad)
        }
        draft.url = "  https://chat.example.com  "
        XCTAssertNil(draft.problem)
        XCTAssertEqual(draft.account?.customURL?.host, "chat.example.com")
    }

    func testDraftLabelFallsBackToTheServiceName() {
        let draft = AccountDraft()
        draft.label = "   "
        XCTAssertEqual(draft.resolvedLabel, "Slack")
        draft.label = " Acme "
        XCTAssertEqual(draft.account?.label, "Acme")
        draft.reset()
        XCTAssertEqual(draft.label, "")
    }

    func testLimitIsClampedWithADefault() throws {
        XCTAssertEqual(try WhisperMCP.scriptArguments(.listChats, [:])["limit"] as? Int, 30)
        XCTAssertEqual(try WhisperMCP.scriptArguments(.listChats, ["limit": 0])["limit"] as? Int, 1)
        XCTAssertEqual(try WhisperMCP.scriptArguments(.listChats, ["limit": 5000])["limit"] as? Int, 200)
        XCTAssertEqual(try WhisperMCP.scriptArguments(.listChats, ["limit": 42])["limit"] as? Int, 42)
    }

    func testRequiredStringsMustBePresentNonBlankAndBounded() throws {
        func missing(_ op: ServiceScripts.Operation, _ input: [String: Any]) -> String? {
            do {
                _ = try WhisperMCP.scriptArguments(op, input)
                return nil
            } catch { return error.key }
        }
        XCTAssertEqual(missing(.readMessages, [:]), "chat")
        XCTAssertEqual(missing(.search, ["query": "  "]), "query")
        XCTAssertEqual(missing(.send, ["chat": "Mam"]), "text")
        XCTAssertEqual(missing(.send, ["chat": "Mam", "text": String(repeating: "x", count: 10_001)]), "text")
        XCTAssertEqual(missing(.send, ["chat": 7, "text": "hi"]), "chat", "not a string")
        let sent = try WhisperMCP.scriptArguments(.send, ["chat": "Mam", "text": "hi", "extra": "dropped"])
        XCTAssertEqual(sent["chat"] as? String, "Mam")
        XCTAssertEqual(sent["text"] as? String, "hi")
        XCTAssertNil(sent["extra"], "only declared arguments reach the page")
    }
}
