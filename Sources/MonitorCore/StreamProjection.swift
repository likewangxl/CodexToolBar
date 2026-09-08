import Foundation

/// Retain only the desktop fields needed by this observer. Tool output and hidden
/// reasoning are never retained or repainted. Array positions stay intact for patches.
enum StreamProjection {
    static let roots: Set<String> = ["id", "title", "recencyAt", "threadRuntimeStatus", "requests", "turnHistory", "turns", "latestTokenUsageInfo"]
    static let omitted: Set<String> = ["aggregatedOutput", "aggregated_output", "encryptedContent", "encrypted_content", "summary", "content", "output", "arguments", "diff", "hookRuns", "command", "stdout", "stderr"]
    static func prune(_ value: Any, root: Bool = false) -> Any {
        if let dict = value as? [String: Any] {
            return dict.reduce(into: [String: Any]()) { result, pair in
                if (root && !roots.contains(pair.key)) || omitted.contains(pair.key) { return }
                result[pair.key] = prune(pair.value)
            }
        }
        if let values = value as? [Any] { return values.map { prune($0) } }
        return value
    }
    static func patches(_ patches: [[String: Any]]) throws -> [[String: Any]] {
        try patches.compactMap { patch in
            let path: [String]
            if let array = patch["path"] as? [Any] { path = array.map { String(describing: $0) } }
            else if let string = patch["path"] as? String, string.isEmpty || string.hasPrefix("/") {
                path = string.isEmpty ? [] : string.dropFirst().components(separatedBy: "/").map { $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~") }
            } else { throw JSONPatch.Failure.invalidPath }
            if let first = path.first, !roots.contains(first) { return nil }
            if path.contains(where: omitted.contains) { return nil }
            var output = patch
            if let value = patch["value"] { output["value"] = prune(value, root: path.isEmpty) }
            return output
        }
    }
}
