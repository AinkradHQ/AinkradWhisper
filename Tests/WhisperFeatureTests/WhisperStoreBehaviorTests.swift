import AinkradAppKit
import AppKit
import XCTest

@testable import WhisperFeature

/// Store behaviour without the network: every account here either hibernates
/// (so the deferred connect loads nothing) or has no URL to load.
@MainActor
final class WhisperStoreBehaviorTests: XCTestCase {
    private func makeStore(_ signals: PluginSignalEmitter = NoopSignals()) -> WhisperStore {
        _ = NSApplication.shared
        return WhisperStore(documents: MemoryDocs(), signals: signals)
    }

    private func blank(_ label: String, keep: Bool? = nil) -> Account {
        Account(service: .custom, label: label, keepConnected: keep)
    }

    // MARK: Accounts

    func testAddSelectsTheNewAccount() {
        let store = makeStore()
        let first = Account(service: .slack, label: "Slack", keepConnected: false)
        let second = Account(service: .teams, label: "Teams", keepConnected: false)
        store.add(first)
        store.add(second)
        XCTAssertEqual(store.accounts.map(\.id), [first.id, second.id])
        XCTAssertEqual(store.selection, second.id)
    }

    func testRenameTrimsAndIgnoresBlankOrUnknown() {
        let store = makeStore()
        let account = blank("Old")
        store.add(account)
        store.rename(account.id, to: "  New  ")
        XCTAssertEqual(store.accounts.first?.label, "New")
        store.rename(account.id, to: " \n ")
        XCTAssertEqual(store.accounts.first?.label, "New")
        store.rename(UUID(), to: "Other")
        XCTAssertEqual(store.accounts.map(\.label), ["New"])
    }

    func testRemoveMovesSelectionAndClearsUnread() {
        let store = makeStore()
        let a = blank("A")
        let b = blank("B")
        store.add(a)
        store.add(b)
        store.remove(b.id)
        XCTAssertEqual(store.accounts.map(\.id), [a.id])
        XCTAssertEqual(store.selection, a.id)
        XCTAssertNil(store.unread[b.id])
        store.remove(a.id)
        XCTAssertNil(store.selection)
    }

    func testFreshLabelSkipsTakenNames() {
        let store = makeStore()
        XCTAssertEqual(store.freshLabel(for: .slack), "Slack")
        store.add(Account(service: .slack, label: "Slack", keepConnected: false))
        store.add(Account(service: .slack, label: "Slack 2", keepConnected: false))
        XCTAssertEqual(store.freshLabel(for: .slack), "Slack 3")
        XCTAssertEqual(store.freshLabel(for: .teams), "Teams")
    }

    func testResolveByIDLabelOrUniqueService() {
        let store = makeStore()
        let work = Account(service: .slack, label: "Work Slack", keepConnected: false)
        let teams = Account(service: .teams, label: "Teams", keepConnected: false)
        store.add(work)
        store.add(teams)
        XCTAssertEqual(store.resolve(work.id.uuidString.lowercased())?.id, work.id)
        XCTAssertEqual(store.resolve("  work slack ")?.id, work.id)
        XCTAssertEqual(store.resolve("slack")?.id, work.id, "service raw value")
        XCTAssertEqual(store.resolve("Teams")?.id, teams.id)
        XCTAssertNil(store.resolve("whatsapp"))
        store.add(Account(service: .slack, label: "Home", keepConnected: false))
        XCTAssertNil(store.resolve("slack"), "two Slacks: the service name is ambiguous")
    }

    func testSetMutedStoresTrueOrNil() {
        let store = makeStore()
        let account = blank("A")
        store.add(account)
        store.setMuted(account.id, true)
        XCTAssertEqual(store.accounts.first?.muted, true)
        store.setMuted(account.id, false)
        XCTAssertNil(store.accounts.first?.muted, "unmuted is the default, stored as nil")
    }

    func testSetKeepConnectedStoresOnlyNonDefaultAndLoadsThePage() {
        let store = makeStore()
        let account = blank("A")
        store.add(account)
        store.setKeepConnected(account.id, false)
        XCTAssertNil(store.accounts.first?.keepConnected, "a web app hibernates by default")
        XCTAssertFalse(store.isLoaded(account.id))
        store.setKeepConnected(account.id, true)
        XCTAssertEqual(store.accounts.first?.keepConnected, true)
        XCTAssertTrue(store.isLoaded(account.id), "keeping an account connected loads it")
    }

    // MARK: Hibernation

    func testHibernateIdleFreesOnlyIdleHibernatablePages() {
        let store = makeStore()
        store.hibernateMinutes = 15
        let now = Date()
        let idle = blank("Idle")
        let recent = blank("Recent")
        let kept = blank("Kept", keep: true)
        let inCall = blank("Call")
        for account in [idle, recent, kept, inCall] {
            store.add(account)
            _ = store.page(for: account)
        }
        store.pages[idle.id]?.lastUsed = now.addingTimeInterval(-16 * 60)
        store.pages[recent.id]?.lastUsed = now.addingTimeInterval(-14 * 60)
        store.pages[kept.id]?.lastUsed = now.addingTimeInterval(-60 * 60)
        store.pages[inCall.id]?.lastUsed = now.addingTimeInterval(-60 * 60)
        store.pages[inCall.id]?.inCallForTesting = true

        store.hibernateIdle(now: now)
        XCTAssertFalse(store.isLoaded(idle.id), "past the cutoff")
        XCTAssertTrue(store.isLoaded(recent.id), "inside the cutoff")
        XCTAssertTrue(store.isLoaded(kept.id), "kept connected")
        XCTAssertTrue(store.isLoaded(inCall.id), "in a call")
    }

    func testHibernateNeverKeepsEveryPage() {
        let store = makeStore()
        let account = blank("A")
        store.add(account)
        _ = store.page(for: account)
        store.hibernateMinutes = 0
        store.hibernateIdle(now: Date().addingTimeInterval(24 * 3600))
        XCTAssertTrue(store.isLoaded(account.id))
    }

    // MARK: Notifications

    func testDecodeTargetJSONAndLegacyID() throws {
        let store = makeStore()
        let account = blank("A")
        store.add(account)
        let target = WhisperStore.NotificationTarget(account: account.id, note: "n1", chat: "Mam")
        let json = String(decoding: try JSONEncoder().encode(target), as: UTF8.self)
        XCTAssertEqual(store.decodeTarget(json)?.note, "n1")
        let legacy = store.decodeTarget(account.id.uuidString)
        XCTAssertEqual(legacy?.account, account.id)
        XCTAssertEqual(legacy?.note, "", "a bare id carries no note")
        XCTAssertNil(store.decodeTarget(UUID().uuidString), "unknown account")
        XCTAssertNil(store.decodeTarget("not a target"))
    }

    func testNotifyEmitsForAnUnmutedAccount() {
        let signals = RecordingSignals()
        let store = makeStore(signals)
        let account = blank("Chat")
        store.add(account)
        store.notify(account.id, PageNotification(id: "1", title: "Mam", body: "hi", tag: ""))
        XCTAssertEqual(signals.emitted.count, 1)
        XCTAssertEqual(signals.emitted.first?.kind, "whisper.message")
        XCTAssertEqual(signals.emitted.first?.title, "Mam")
        XCTAssertEqual(signals.emitted.first?.dedupeKey, "\(account.id.uuidString):Mam")
        XCTAssertEqual(signals.emitted.first?.actions, 1, "a message offers Mark as read")
    }

    func testNotifyIsSilentWhenMutedOrUnknown() {
        let signals = RecordingSignals()
        let store = makeStore(signals)
        let account = blank("Chat")
        store.add(account)
        store.setMuted(account.id, true)
        store.notify(account.id, PageNotification(id: "1", title: "Mam", body: "hi", tag: ""))
        store.notify(UUID(), PageNotification(id: "2", title: "Mam", body: "hi", tag: ""))
        XCTAssertTrue(signals.emitted.isEmpty)
    }

    func testCallNotificationIsAWarningWithoutActions() {
        let signals = RecordingSignals()
        let store = makeStore(signals)
        let account = blank("Chat")
        store.add(account)
        store.notify(account.id, PageNotification(id: "1", title: "Mam", body: "Incoming voice call", tag: ""))
        XCTAssertEqual(signals.emitted.first?.kind, "whisper.call")
        XCTAssertEqual(signals.emitted.first?.severity, .warning)
        XCTAssertEqual(signals.emitted.first?.actions, 0)
        XCTAssertNil(signals.emitted.first?.dedupeKey)
    }

    func testSharedServiceTitleNamesTheAccount() {
        let signals = RecordingSignals()
        let store = makeStore(signals)
        let a = blank("Work")
        store.add(a)
        store.add(blank("Home"))
        store.notify(a.id, PageNotification(id: "1", title: "", body: "", tag: ""))
        XCTAssertEqual(signals.emitted.first?.title, "Work · Work", "no sender: the label stands in")
    }
}

/// Records what the store emits.
@MainActor
final class RecordingSignals: PluginSignalEmitter {
    struct Emitted {
        let kind: String
        let severity: SignalSeverity
        let title: String
        let actions: Int
        let dedupeKey: String?
    }
    var emitted: [Emitted] = []

    func emit(
        kind: String, severity: SignalSeverity, title: String, body: String?,
        importance: SignalImportance, deepLink: SignalDeepLink?,
        actions: [SignalAction], dedupeKey: String?
    ) {
        emitted.append(
            Emitted(kind: kind, severity: severity, title: title, actions: actions.count, dedupeKey: dedupeKey))
    }
    func own(limit: Int) -> [SignalEvent] { [] }
    func handleAction(
        _ actionID: String,
        _ handler: @escaping @MainActor () async -> Void
    ) -> AgentActionToken {
        AgentActionToken()
    }
    func removeActionHandler(_ token: AgentActionToken) {}
}
