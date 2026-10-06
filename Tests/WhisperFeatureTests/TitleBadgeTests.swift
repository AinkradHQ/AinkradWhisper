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
        let meet = Account(service: .meet, label: "Meet")
        XCTAssertTrue(meet.owns(URL(string: "https://meet.google.com/abc-defg-hij")))
        XCTAssertTrue(meet.owns(URL(string: "https://accounts.google.com/signin")))
        XCTAssertFalse(meet.owns(URL(string: "https://notgoogle.com")))
        let web = Account(service: .custom, label: "Chat", customURL: URL(string: "https://chat.example.com"))
        XCTAssertTrue(web.owns(URL(string: "https://chat.example.com/room")))
        XCTAssertFalse(web.owns(URL(string: "https://example.com")))
    }

    func testNotificationCallsAndGrouping() {
        let call = PageNotification(id: "1", title: "Mam", body: "Incoming voice call", tag: "")
        XCTAssertTrue(call.isCall)
        XCTAssertTrue(PageNotification(id: "2", title: "Ahmed is calling you", body: "", tag: "").isCall)
        XCTAssertTrue(PageNotification(id: "3", title: "Ghada", body: "invited you to a huddle", tag: "").isCall)
        XCTAssertFalse(PageNotification(id: "4", title: "Islam", body: "see you at the call later?", tag: "").isCall)

        let account = UUID()
        let a = PageNotification(id: "5", title: "Mam", body: "hi", tag: "")
        let b = PageNotification(id: "6", title: "Mam", body: "again", tag: "")
        XCTAssertEqual(a.groupKey(account: account), b.groupKey(account: account))
        let tagged = PageNotification(id: "7", title: "New message", body: "x", tag: "C0123")
        XCTAssertEqual(tagged.groupKey(account: account), "\(account.uuidString):C0123")
    }

    func testAccountsSavedBeforeMuteStillDecode() throws {
        let old = #"{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","service":"slack","label":"Slack"}"#
        let account = try JSONDecoder().decode(Account.self, from: Data(old.utf8))
        XCTAssertFalse(account.isMuted)
    }

    func testKeepConnectedDefaults() {
        XCTAssertTrue(
            Account(service: .whatsapp, label: "W", keepConnected: false).staysConnected, "WhatsApp cannot hibernate")
        XCTAssertTrue(Account(service: .slack, label: "S").staysConnected)
        XCTAssertTrue(Account(service: .teams, label: "T").staysConnected)
        XCTAssertFalse(Account(service: .meet, label: "M").staysConnected)
        XCTAssertFalse(Account(service: .slack, label: "S", keepConnected: false).staysConnected)
        XCTAssertTrue(Account(service: .meet, label: "M", keepConnected: true).staysConnected)
    }
}
