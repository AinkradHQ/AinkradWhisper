import Foundation
import AinkradAppKit

/// The assistant's view of Whisper: read chats and, with approval, send.
/// Every tool works with the pane closed — the store loads the account's page
/// off screen when it has to.
@MainActor enum WhisperMCP {
    static func make(store: WhisperStore, log: PluginLogger) -> MCPAppServer {
        let server = MCPAppServer(appID: WhisperApp.id)
        let account = #""account":{"type":"string","description":"Account label, service name (slack, teams, whatsapp) or id, from list_accounts."}"#
        let limit = #""limit":{"type":"integer","minimum":1,"maximum":200,"description":"Default 30."}"#
        let chat = #""chat":{"type":"string","description":"Chat id or name from list_chats (Slack: #channel or @person)."}"#

        let tools: [MCPToolSpec] = [
            MCPToolSpec(
                name: "list_accounts",
                description: "Lists the messaging accounts in Whisper (Slack, Teams, WhatsApp) with unread counts.",
                schemaJSON: #"{"type":"object","properties":{}}"#, readOnly: true) { _ in
                    let rows = store.accounts.map { a -> [String: Any] in
                        ["id": a.id.uuidString, "label": a.label, "service": a.service.rawValue,
                         "unread": store.unread[a.id] ?? 0, "loaded": store.isLoaded(a.id)]
                    }
                    return AgentActionResult(text: json(rows), isError: false)
                },
            MCPToolSpec(
                name: "list_chats",
                description: "Lists an account's chats. WhatsApp returns only the chats in its recent list.",
                schemaJSON: #"{"type":"object","properties":{\#(account),\#(limit)},"required":["account"]}"#,
                readOnly: true) { await run(.listChats, $0, store) },
            MCPToolSpec(
                name: "read_messages",
                description: "Reads the latest messages in one chat, oldest first. On WhatsApp this opens the chat, which marks it read.",
                schemaJSON: #"{"type":"object","properties":{\#(account),\#(chat),\#(limit)},"required":["account","chat"]}"#,
                readOnly: true) { await run(.readMessages, $0, store) },
            MCPToolSpec(
                name: "search",
                description: "Searches one account. Slack searches message text; Teams and WhatsApp match chat names and each chat's last message.",
                schemaJSON: #"{"type":"object","properties":{\#(account),"query":{"type":"string"},\#(limit)},"required":["account","query"]}"#,
                readOnly: true) { await run(.search, $0, store) },
            MCPToolSpec(
                name: "send_message",
                description: "Sends a message as the user. Confirm the account, chat and exact text with the user first.",
                schemaJSON: #"{"type":"object","properties":{\#(account),\#(chat),"text":{"type":"string","maxLength":10000}},"required":["account","chat","text"]}"#,
                destructive: true) { await run(.send, $0, store) },
        ]
        let rejected = tools.filter { !server.addTool($0) }.map(\.name)
        if !rejected.isEmpty { log.error("Whisper MCP: tools rejected — \(rejected.joined(separator: ", "))") }
        return server
    }

    private static func run(_ operation: ServiceScripts.Operation, _ argumentsJSON: String,
                            _ store: WhisperStore) async -> AgentActionResult {
        let input = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        guard let reference = input["account"] as? String, let account = store.resolve(reference) else {
            return failure("Unknown account. Call list_accounts and pass a label or id.")
        }
        guard let script = ServiceScripts.script(operation, for: account.service) else {
            return failure("\(account.label) (\(account.service.name)) has no chats for the assistant; the tools cover Slack, Teams and WhatsApp.")
        }
        var arguments: [String: Any] = ["limit": min(max(input["limit"] as? Int ?? 30, 1), 200)]
        for key in operation.required {
            guard let value = input[key] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 10_000 else {
                return failure("`\(key)` is required (1–10000 characters).")
            }
            arguments[key] = value
        }
        let page = await store.loadedPage(for: account)
        do {
            return AgentActionResult(text: try await page.run(script, arguments: arguments), isError: false)
        } catch {
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
            return failure("\(account.label): \(message ?? error.localizedDescription)")
        }
    }

    private static func failure(_ text: String) -> AgentActionResult { AgentActionResult(text: text, isError: true) }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}
