import Foundation

enum AppGroup {
    private static let fallbackIdentifier = "group.com.example.LiveLingo"
    static var identifier: String {
        signedApplicationGroups().first ?? fallbackIdentifier
    }

    private static func signedApplicationGroups() -> [String] {
        guard let profileURL = Bundle.main.url(
            forResource: "embedded",
            withExtension: "mobileprovision"
        ),
        let profileData = try? Data(contentsOf: profileURL),
        let startRange = profileData.range(of: Data("<plist".utf8)),
        let endRange = profileData.range(of: Data("</plist>".utf8)),
        startRange.lowerBound < endRange.upperBound
        else { return [] }

        let plistData = profileData.subdata(in: startRange.lowerBound..<endRange.upperBound)
        guard let profile = try? PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        ) as? [String: Any],
        let entitlements = profile["Entitlements"] as? [String: Any],
        let groups = entitlements["com.apple.security.application-groups"] as? [String]
        else { return [] }

        return groups
    }
    static let frameName = "latest-frame.jpg"
    static let observationName = "latest-observations.json"
    static let sourceLanguageKey = "ocr-source-language"
    static let broadcastActiveKey = "broadcast-active"
    static let broadcastHeartbeatKey = "broadcast-heartbeat"
    static let stopBroadcastKey = "stop-broadcast-requested"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var frameURL: URL? { containerURL?.appendingPathComponent(frameName) }
    static var observationURL: URL? { containerURL?.appendingPathComponent(observationName) }

    static var preferences: UserDefaults? { UserDefaults(suiteName: identifier) }

    static var recognitionLanguages: [String] {
        recognitionLanguages(for: preferences?.string(forKey: sourceLanguageKey) ?? "")
    }

    static func recognitionLanguages(for code: String) -> [String] {
        switch code {
        case "zh-Hans", "zh": return ["zh-Hans", "zh-Hant", "en-US"]
        case "ja": return ["ja-JP", "en-US"]
        case "ko": return ["ko-KR", "en-US"]
        case "es": return ["es-ES", "en-US"]
        case "fr": return ["fr-FR", "en-US"]
        case "de": return ["de-DE", "en-US"]
        case "en": return ["en-US"]
        default: return ["zh-Hans", "ja-JP", "ko-KR", "en-US"]
        }
    }
}

struct ScreenObservation: Codable, Identifiable, Hashable {
    let id: UUID
    let text: String
    /// Vision coordinates: normalized, origin at bottom-left.
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(id: UUID = UUID(), text: String, x: Double, y: Double, width: Double, height: Double) {
        self.id = id
        self.text = text
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
