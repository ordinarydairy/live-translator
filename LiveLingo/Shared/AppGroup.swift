import Foundation

enum AppGroup {
    static let identifier = "group.com.example.LiveLingo"
    static let frameName = "latest-frame.jpg"
    static let observationName = "latest-observations.json"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var frameURL: URL? { containerURL?.appendingPathComponent(frameName) }
    static var observationURL: URL? { containerURL?.appendingPathComponent(observationName) }
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

