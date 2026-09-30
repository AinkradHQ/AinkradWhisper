import Foundation

public enum Service: String, Codable, CaseIterable, Sendable {
    case slack, teams, whatsapp, custom

    var name: String {
        switch self {
        case .slack: "Slack"
        case .teams: "Teams"
        case .whatsapp: "WhatsApp"
        case .custom: "Web"
        }
    }

    var icon: String {
        switch self {
        case .slack: "number"
        case .teams: "person.3"
        case .whatsapp: "phone.bubble"
        case .custom: "globe"
        }
    }

    var defaultURL: URL? {
        switch self {
        case .slack: URL(string: "https://app.slack.com/client")
        case .teams: URL(string: "https://teams.microsoft.com/v2/")
        case .whatsapp: URL(string: "https://web.whatsapp.com")
        case .custom: nil
        }
    }

    /// Domains that stay inside the app: the service itself and its sign-in
    /// flows. Links anywhere else open in the default browser, and only these
    /// origins may ask for the camera and microphone.
    var domains: [String] {
        switch self {
        case .slack: ["slack.com", "slack-edge.com"]
        case .teams: ["microsoft.com", "microsoftonline.com", "live.com", "office.com",
                      "office.net", "cloud.microsoft", "skype.com", "sharepoint.com"]
        case .whatsapp: ["whatsapp.com", "whatsapp.net"]
        case .custom: []
        }
    }

    /// Slack and Teams reload fast and their assistant paths reload on demand;
    /// WhatsApp must stay loaded to keep receiving (its session is the page).
    var hibernates: Bool { self != .whatsapp }
}

public struct Account: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var service: Service
    public var label: String
    /// Only for `.custom`; the others use `service.defaultURL`.
    public var customURL: URL?

    var url: URL? { customURL ?? service.defaultURL }

    func owns(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        let domains = service == .custom ? [self.url?.host?.lowercased()].compactMap { $0 } : service.domains
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// Unread count from the page title — the one signal every web client already
/// keeps current: "(3) WhatsApp", "(2) Chat | … | Microsoft Teams", Slack's
/// leading "*" for unread channels (no count, so it reads as 1).
func unreadCount(fromTitle title: String) -> Int {
    if let match = title.firstMatch(of: /^\((\d+)\)/) { return Int(match.1) ?? 0 }
    return title.hasPrefix("*") ? 1 : 0
}
