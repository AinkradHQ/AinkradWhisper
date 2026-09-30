import XCTest
@testable import WhisperFeature

final class TitleBadgeTests: XCTestCase {
    func testUnreadFromTitle() {
        XCTAssertEqual(unreadCount(fromTitle: "(3) WhatsApp"), 3)
        XCTAssertEqual(unreadCount(fromTitle: "(12) Chat | Acme | Microsoft Teams"), 12)
        XCTAssertEqual(unreadCount(fromTitle: "* general - Acme - Slack"), 1)
        XCTAssertEqual(unreadCount(fromTitle: "WhatsApp"), 0)
        XCTAssertEqual(unreadCount(fromTitle: "Chat | Microsoft Teams (2)"), 0)
    }

    func testOwnsServiceDomainsOnly() {
        let teams = Account(service: .teams, label: "Teams")
        XCTAssertTrue(teams.owns(URL(string: "https://login.microsoftonline.com/x")))
        XCTAssertTrue(teams.owns(URL(string: "https://teams.cloud.microsoft/v2/")))
        XCTAssertFalse(teams.owns(URL(string: "https://evilmicrosoft.com")))
        XCTAssertFalse(teams.owns(URL(string: "https://github.com")))
        let web = Account(service: .custom, label: "Chat", customURL: URL(string: "https://chat.example.com"))
        XCTAssertTrue(web.owns(URL(string: "https://chat.example.com/room")))
        XCTAssertFalse(web.owns(URL(string: "https://example.com")))
    }
}
