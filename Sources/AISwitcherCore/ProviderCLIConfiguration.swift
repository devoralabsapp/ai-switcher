import Foundation
public enum ProviderCLIConfiguration {
    public static let claudeArguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--safe-mode", "--no-session-persistence", "--settings", "{\"disableAllHooks\":true}", "--mcp-config", "{\"mcpServers\":{}}", "--strict-mcp-config"]
    public static let antigravityArguments = ["-p", "/usage", "--output-format", "json"]
    public static func accepts(version: String, agent: AIAgent) -> Bool {
        let regex = try! NSRegularExpression(pattern: #"(?:^|\s)(\d+)\.(\d+)\.(\d+)(?:\s|$|[-+])"#)
        guard let match = regex.firstMatch(in: version, range: NSRange(version.startIndex..., in: version)) else { return false }
        let values = (1...3).compactMap { Range(match.range(at: $0), in: version).flatMap { Int(version[$0]) } }
        guard values.count == 3 else { return false }
        if agent == .antigravity && !version.lowercased().contains("antigravity") && !version.lowercased().contains("agy") && version.trimmingCharacters(in: .whitespacesAndNewlines).range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) == nil { return false }
        let minimum = agent == .claude ? [2, 1, 270] : [1, 1, 12]
        if agent == .claude && !version.lowercased().contains("claude") { return false }
        for i in 0..<3 { if values[i] != minimum[i] { return values[i] > minimum[i] } }
        return true
    }
}
