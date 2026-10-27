import Foundation

/// Shared, code-native artwork used by both native frontends. Coordinates use a 360 × 210 canvas.
public struct SeasonalPoint: Codable, Sendable { public let x, y: Double }
public struct SeasonalMark: Codable, Sendable {
    public let kind: String
    public let x, y, w, h, radius, width, size: Double?
    public let color: String
    public let stroke, text: String?
    public let points: [SeasonalPoint]?
    public let closed: Bool?
}
public struct SeasonalTheme: Sendable {
    public let id, label, symbol: String
    public let companion: UInt32
    public var marks: [SeasonalMark] { Self.artwork[id] ?? [] }
    private static let artwork: [String: [SeasonalMark]] = {
        guard let url = Bundle.module.url(forResource: "SeasonalScenes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [SeasonalMark]].self, from: data) else { return [:] }
        return decoded
    }()
}

extension AppTheme {
    public var seasonal: SeasonalTheme? {
        switch self {
        case .halloween: return .init(id: rawValue, label: "AFTER DARK", symbol: "moon.stars.fill", companion: 0xc5a0ee)
        case .christmas: return .init(id: rawValue, label: "MERRY & BRIGHT", symbol: "snowflake", companion: 0xf2a7ad)
        case .tetHoliday: return .init(id: rawValue, label: "A LUCKY NEW START", symbol: "sparkles", companion: 0xf49c87)
        case .blackFriday: return .init(id: rawValue, label: "BLACK FRIDAY EDITION", symbol: "tag.fill", companion: 0xe1ddd1)
        default: return nil
        }
    }
}
