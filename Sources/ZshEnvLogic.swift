import Foundation
import CryptoKit

enum ShellValueLogic {
    static func matchesSearch(_ query: String, name: String, value: String, note: String) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return true }
        return [name, value, note].contains { $0.localizedCaseInsensitiveContains(normalizedQuery) }
    }

    static func reconciledSelection(current: UUID?, visibleIDs: [UUID]) -> UUID? {
        guard let current, visibleIDs.contains(current) else { return visibleIDs.first }
        return current
    }

    static func references(in value: String) -> [String] {
        let pattern = #"(?<!\\)\$(?:\{([A-Za-z_][A-Za-z0-9_]*)[^}]*\}|([A-Za-z_][A-Za-z0-9_]*))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        var names: [String] = []
        for match in regex.matches(in: value, range: range) {
            for index in [1, 2] where match.range(at: index).location != NSNotFound {
                if let swiftRange = Range(match.range(at: index), in: value) {
                    let name = String(value[swiftRange])
                    if !names.contains(name) { names.append(name) }
                }
            }
        }
        return names
    }

    static func containsExpansion(_ value: String) -> Bool {
        !references(in: value).isEmpty
            || value.range(of: #"(?<!\\)\$\("#, options: .regularExpression) != nil
            || value.range(of: #"(?<!\\)`"#, options: .regularExpression) != nil
    }

    static func quote(_ value: String) -> String {
        if containsExpansion(value) {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func decode(_ expression: String) -> String {
        guard expression.count >= 2 else { return expression }
        if expression.hasPrefix("'"), expression.hasSuffix("'") {
            return String(expression.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
        }
        if expression.hasPrefix("\""), expression.hasSuffix("\"") {
            return String(expression.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return expression
    }

    static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func dependencyOrderViolation(in items: [(name: String, expression: String)]) -> (consumer: String, dependency: String)? {
        let positions = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.name, $0.offset) })
        for (index, item) in items.enumerated() {
            for dependency in references(in: item.expression) where dependency != item.name {
                if let dependencyIndex = positions[dependency], dependencyIndex > index {
                    return (item.name, dependency)
                }
            }
        }
        return nil
    }
}
