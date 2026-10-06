import AinkradAppKit
import Foundation
import XCTest

@testable import WhisperFeature

@MainActor
final class WhisperStoreTests: XCTestCase {
    func testCorruptDocumentIsSetAsideNotOverwritten() {
        let seed = Data("{not json".utf8)
        let docs = MemoryDocs()
        docs.setData(seed, forKey: "state")
        let store = WhisperStore(documents: docs, signals: NoopSignals())
        // One edit that persists. No accounts, so the 3 s connectKeptAccounts
        // task creates no web view.
        store.hibernateMinutes = 5
        let backups = docs.storage.keys.filter { $0.hasPrefix("state.corrupt-") }
        XCTAssertEqual(backups.count, 1, "corrupt bytes were not set aside")
        XCTAssertEqual(docs.storage[backups.first ?? ""], seed, "backup does not hold the seed bytes")
    }

    func testUnverifiableSetAsideKeepsOriginalAndStopsSaving() {
        let seed = Data("{not json".utf8)
        let docs = RejectingCorruptDocs()
        docs.setData(seed, forKey: "state")
        let store = WhisperStore(documents: docs, signals: NoopSignals())
        store.hibernateMinutes = 5
        XCTAssertEqual(
            docs.storage["state"], seed,
            "the only copy of the user's data was overwritten")
    }
}

/// In-memory document store for the store tests.
final class MemoryDocs: PluginDocumentStore {
    var storage: [String: Data] = [:]
    func data(forKey key: String) -> Data? { storage[key] }
    func setData(_ data: Data?, forKey key: String) { storage[key] = data }
}

/// In-memory document store whose `setData` ignores backup keys, simulating a
/// failed verification read-back after the set-aside write.
final class RejectingCorruptDocs: PluginDocumentStore {
    var storage: [String: Data] = [:]
    func data(forKey key: String) -> Data? { storage[key] }
    func setData(_ data: Data?, forKey key: String) {
        if key.contains(".corrupt-") { return }
        storage[key] = data
    }
}

/// No-op signal emitter: the store tests never notify.
@MainActor
final class NoopSignals: PluginSignalEmitter {
    func emit(
        kind: String, severity: SignalSeverity, title: String, body: String?,
        importance: SignalImportance, deepLink: SignalDeepLink?,
        actions: [SignalAction], dedupeKey: String?
    ) {}
    func own(limit: Int) -> [SignalEvent] { [] }
    func handleAction(
        _ actionID: String,
        _ handler: @escaping @MainActor () async -> Void
    ) -> AgentActionToken {
        AgentActionToken()
    }
    func removeActionHandler(_ token: AgentActionToken) {}
}
