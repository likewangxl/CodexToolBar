import Foundation

/// Only live, observed transitions produce unread completions. Initial history,
/// failures and disconnected snapshots never manufacture a notification.
public struct CompletionNotifications {
    private var states: [String: WorkStatus] = [:]
    public private(set) var unread: Set<String> = []
    public init() {}
    public mutating func update(_ tasks: [TaskState]) {
        let ids = Set(tasks.map(\.id))
        states = states.filter { ids.contains($0.key) }
        unread.formIntersection(ids)
        for task in tasks {
            guard task.isLive, task.connectionIssue == nil else { continue }
            if task.status == .completed, states[task.id]?.active == true { unread.insert(task.id) }
            states[task.id] = task.status
        }
    }
    public mutating func acknowledge(_ id: String) { unread.remove(id) }
}

/// Read just the desktop appearance tables emitted by Codex. This is a bounded
/// whitelist reader, not a general TOML parser; unknown settings are ignored.
public struct DesktopThemeSettings: Equatable {
    public var dark: Bool
    public var surface: String
    public var ink: String
    public var accent: String
    public var uiFont: String?
    public var codeFont: String?
    public init(config: String = "", systemDark: Bool = false) {
        var values: [String: String] = [:], section = ""
        for raw in config.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line.hasSuffix("]") ? String(line.dropFirst().dropLast()) : ""; continue }
            guard section == "desktop" || section.hasPrefix("desktop.appearance"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard let quote = value.first, quote == "\"" || quote == "'", !value.hasPrefix(String(repeating: String(quote), count: 3)),
                  let end = value.dropFirst().firstIndex(of: quote) else { continue }
            let tail = value[value.index(after: end)...].trimmingCharacters(in: .whitespaces)
            guard tail.isEmpty || tail.hasPrefix("#") else { continue }
            values[section + "." + key] = String(value[value.index(after: value.startIndex)..<end])
        }
        let mode = values["desktop.appearanceTheme"]
        dark = mode == "dark" || (mode != "light" && systemDark)
        let prefix = "desktop.appearance\(dark ? "Dark" : "Light")ChromeTheme."
        func color(_ key: String, _ fallback: String) -> String {
            guard let value = values[prefix + key], value.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else { return fallback }
            return value
        }
        surface = color("surface", dark ? "#000000" : "#fcfcfc")
        ink = color("ink", dark ? "#ededed" : "#0d0d0d")
        accent = color("accent", "#3a83f7")
        func font(_ key: String) -> String? {
            let raw = values[prefix + "fonts." + key + "Face.postscriptName"] ?? values[prefix + "fonts." + key]
            let clean = raw?.split(separator: ",").first.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            return clean?.isEmpty == false ? clean : nil
        }
        uiFont = font("ui"); codeFont = font("code")
    }
}
