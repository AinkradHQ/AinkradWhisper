import AinkradAppKit
import Foundation

/// The assistant's view of Whisper: read chats and, with approval, send.
/// Every tool works with the pane closed — the store loads the account's page
/// off screen when it has to.
@MainActor enum WhisperMCP {
    static func make(store: WhisperStore, log: PluginLogger) -> MCPAppServer {
        let server = MCPAppServer(appID: WhisperApp.id)
        let account =
            #""account":{"type":"string","description":"Account label, service name (slack, teams, whatsapp) or id, from list_accounts."}"#
        let limit = #""limit":{"type":"integer","minimum":1,"maximum":200,"description":"Default 30."}"#
        let chat =
            #""chat":{"type":"string","description":"Chat id or name from list_chats (Slack: #channel or @person)."}"#

        let tools: [MCPToolSpec] = [
            MCPToolSpec(
                name: "list_accounts",
                description: "Lists the messaging accounts in Whisper (Slack, Teams, WhatsApp) with unread counts.",
                schemaJSON: #"{"type":"object","properties":{}}"#, readOnly: true
            ) { _ in
                let rows = store.accounts.map { a -> [String: Any] in
                    [
                        "id": a.id.uuidString, "label": a.label, "service": a.service.rawValue,
                        "unread": store.unread[a.id] ?? 0, "loaded": store.isLoaded(a.id),
                    ]
                }
                return AgentActionResult(text: json(rows), isError: false)
            },
            MCPToolSpec(
                name: "list_chats",
                description: "Lists an account's chats. WhatsApp returns only the chats in its recent list.",
                schemaJSON: #"{"type":"object","properties":{\#(account),\#(limit)},"required":["account"]}"#,
                readOnly: true
            ) { await run(.listChats, $0, store) },
            MCPToolSpec(
                name: "read_messages",
                description:
                    "Reads the latest messages in one chat, oldest first. On WhatsApp this opens the chat, which marks it read.",
                schemaJSON:
                    #"{"type":"object","properties":{\#(account),\#(chat),\#(limit)},"required":["account","chat"]}"#,
                readOnly: true
            ) { await run(.readMessages, $0, store) },
            MCPToolSpec(
                name: "search",
                description:
                    "Searches one account. Slack searches message text; Teams and WhatsApp match chat names and each chat's last message.",
                schemaJSON:
                    #"{"type":"object","properties":{\#(account),"query":{"type":"string"},\#(limit)},"required":["account","query"]}"#,
                readOnly: true
            ) { await run(.search, $0, store) },
            MCPToolSpec(
                name: "send_message",
                description:
                    "Sends a message as the user. Confirm the account, chat and exact text with the user first.",
                schemaJSON:
                    #"{"type":"object","properties":{\#(account),\#(chat),"text":{"type":"string","maxLength":10000}},"required":["account","chat","text"]}"#,
                destructive: true
            ) { await run(.send, $0, store) },
        ]
        let events = MCPToolSpec(
            name: "list_events",
            description:
                "Lists upcoming meetings and events from the Teams (Outlook) calendar and the Google Meet schedule, soonest first. Slack has no calendar of its own. Omit account to read every calendar.",
            schemaJSON:
                #"{"type":"object","properties":{"account":{"type":"string","description":"Optional: a Teams or Google Meet account from list_accounts."},"days":{"type":"integer","minimum":1,"maximum":14,"description":"How many days ahead, from today. Default 7."}}}"#,
            readOnly: true
        ) { await listEvents($0, store) }
        let rejected = (tools + [events]).filter { !server.addTool($0) }.map(\.name)
        if !rejected.isEmpty { log.error("Whisper MCP: tools rejected — \(rejected.joined(separator: ", "))") }
        return server
    }

    private static func run(
        _ operation: ServiceScripts.Operation, _ argumentsJSON: String,
        _ store: WhisperStore
    ) async -> AgentActionResult {
        let input = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        guard let reference = input["account"] as? String, let account = store.resolve(reference) else {
            return failure("Unknown account. Call list_accounts and pass a label or id.")
        }
        guard let script = ServiceScripts.script(operation, for: account.service) else {
            return failure(
                "\(account.label) (\(account.service.name)) has no chats for the assistant; the tools cover Slack, Teams and WhatsApp."
            )
        }
        let arguments: [String: Any]
        do { arguments = try scriptArguments(operation, input) } catch {
            return failure("`\(error.key)` is required (1–10000 characters).")
        }
        let page = await store.loadedPage(for: account)
        do {
            return AgentActionResult(text: try await page.run(script, arguments: arguments), isError: false)
        } catch {
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
            return failure("\(account.label): \(message ?? error.localizedDescription)")
        }
    }

    struct MissingArgument: Error { let key: String }

    /// The script's JS variables: `limit` clamped to 1…200 (default 30), plus
    /// each string the operation requires, non-blank and at most 10000 characters.
    static func scriptArguments(
        _ operation: ServiceScripts.Operation, _ input: [String: Any]
    ) throws(MissingArgument) -> [String: Any] {
        var arguments: [String: Any] = ["limit": min(max(input["limit"] as? Int ?? 30, 1), 200)]
        for key in operation.required {
            guard let value = input[key] as? String,
                !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 10_000
            else { throw MissingArgument(key: key) }
            arguments[key] = value
        }
        return arguments
    }

    /// Reads each calendar account in turn and merges the events by start
    /// time. One account failing (signed out, mid-meeting) is reported next to
    /// the others' events rather than failing the whole call.
    private static func listEvents(_ argumentsJSON: String, _ store: WhisperStore) async -> AgentActionResult {
        let input = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let days = min(max(input["days"] as? Int ?? 7, 1), 14)
        let targets: [Account]
        if let reference = input["account"] as? String {
            guard let account = store.resolve(reference) else {
                return failure("Unknown account. Call list_accounts and pass a label or id.")
            }
            guard CalendarScripts.script(for: account.service) != nil else {
                return failure("\(account.label) (\(account.service.name)) has no calendar; Teams and Google Meet do.")
            }
            targets = [account]
        } else {
            targets = store.accounts.filter { CalendarScripts.script(for: $0.service) != nil }
            if targets.isEmpty { return failure("No Teams or Google Meet account in Whisper.") }
        }
        var events: [[String: Any]] = []
        var errors: [[String: String]] = []
        for account in targets {
            guard let script = CalendarScripts.script(for: account.service) else { continue }
            let page = await store.loadedPage(for: account)
            do {
                // One retry: a page that just woke from hibernation can still be
                // redirecting through sign-in, which discards a running script.
                let json: String
                do { json = try await page.run(script, arguments: ["days": days]) } catch {
                    try? await Task.sleep(for: .seconds(3))
                    json = try await page.run(script, arguments: ["days": days])
                }
                let rows = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] ?? []
                events += rows.map {
                    $0.merging(["account": account.label, "service": account.service.name]) { a, _ in a }
                }
            } catch {
                let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                errors.append(["account": account.label, "error": message ?? error.localizedDescription])
            }
        }
        events.sort { ($0["startMs"] as? Double ?? 0) < ($1["startMs"] as? Double ?? 0) }
        return AgentActionResult(
            text: json(["days": days, "events": events, "errors": errors]),
            isError: events.isEmpty && !errors.isEmpty)
    }

    private static func failure(_ text: String) -> AgentActionResult { AgentActionResult(text: text, isError: true) }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}
