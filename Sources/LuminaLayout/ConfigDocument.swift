import Foundation

/// A field that the form can edit without re-encoding the rest of the document.
public struct ConfigField: Hashable, Sendable {
    public let key: String
    public let table: String?

    public init(_ key: String, table: String? = nil) {
        self.key = key
        self.table = table
    }
}

/// Conservative TOML editing: untouched bytes, comments and unknown settings survive.
/// Unsupported spellings of an edited field are rejected instead of adding a duplicate.
public struct ConfigDocument: Sendable {
    public let text: String

    public init(text: String) { self.text = text }

    public static func quote(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 34: result += "\\\""
            case 92: result += "\\\\"
            case 8: result += "\\b"
            case 9: result += "\\t"
            case 10: result += "\\n"
            case 12: result += "\\f"
            case 13: result += "\\r"
            case 0...31, 127: result += String(format: "\\u%04X", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    public func value(for field: ConfigField) throws -> String? {
        let location = try locate(field)
        guard let range = location.value else { return nil }
        return String(Array(text)[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func setting(_ literal: String, for field: ConfigField) throws -> String {
        let location = try locate(field)
        var chars = Array(text)
        if let range = location.value {
            chars.replaceSubrange(range, with: literal)
        } else if let insertion = location.insertion {
            let prefix = insertion > 0 && !chars[insertion - 1].isNewline ? "\n" : ""
            chars.insert(contentsOf: Array(prefix + "\(field.key) = \(literal)\n"), at: insertion)
        } else {
            let prefix = chars.isEmpty || chars.last?.isNewline == true ? "" : "\n"
            chars.append(contentsOf: Array(prefix + "\n[\(field.table!)]\n\(field.key) = \(literal)\n"))
        }
        let candidate = String(chars)
        // Validate syntax and the application's value constraints before returning text.
        _ = try parseConfig(text: candidate, defaults: .bundledDefault).get()
        return candidate
    }

    private struct Location {
        var value: Range<Int>?
        var insertion: Int?
    }

    private func locate(_ field: ConfigField) throws -> Location {
        guard isBare(field.key), field.table.map(isBare) ?? true else {
            throw ConfigError("Unsupported config field")
        }
        let chars = Array(text)
        var table: String?
        var result = Location(value: nil, insertion: field.table == nil ? 0 : nil)
        for statement in try statements(chars) {
            let raw = String(chars[statement]).trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty || raw.hasPrefix("#") { continue }
            if raw.hasPrefix("[") {
                let header = String(raw.prefix { $0 != "#" }).trimmingCharacters(in: .whitespaces)
                if table == field.table, result.insertion == nil { result.insertion = statement.lowerBound }
                if header == "[\(field.table ?? "")]" {
                    table = field.table
                    result.insertion = statement.upperBound < chars.count ? statement.upperBound + 1 : statement.upperBound
                } else {
                    // Quoted/dotted table forms must never result in a duplicate table.
                    if let target = field.table, header.contains(target), !header.hasPrefix("[[") {
                        throw ConfigError("Edit [\(target)] in the config file: its table spelling is not supported by the form")
                    }
                    table = header
                }
                continue
            }
            guard let equals = statement.first(where: { chars[$0] == "=" }) else { continue }
            let key = String(chars[statement.lowerBound..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
            if table == nil, let target = field.table,
               key == target || key.hasPrefix(target + ".") || key == "\"\(target)\"" || key == "'\(target)'" {
                throw ConfigError("Edit \(target) in the config file: dotted keys and inline tables are not supported by the form")
            }
            guard table == field.table else { continue }
            if key != field.key {
                let unquoted = key.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if unquoted == field.key || key.hasPrefix(field.key + ".") {
                    throw ConfigError("Edit \(field.key) in the config file: its key spelling is not supported by the form")
                }
                continue
            }
            guard result.value == nil else { throw ConfigError("Duplicate config key: \(field.key)") }
            var start = equals + 1
            while start < statement.upperBound, chars[start].isWhitespace { start += 1 }
            let end = try valueEnd(chars, from: start, through: statement.upperBound)
            result.value = start..<end
        }
        if table == field.table { result.insertion = chars.count }
        return result
    }

    private func isBare(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }

    /// Split only at unquoted newlines outside arrays and inline tables.
    private func statements(_ chars: [Character]) throws -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        var index = 0
        var depth = 0
        var quote: Character?
        var triple = false
        var escaped = false
        var comment = false
        while index < chars.count {
            let c = chars[index]
            if comment {
                if c.isNewline { comment = false }
            } else if let q = quote {
                if escaped { escaped = false }
                else if q == "\"", c == "\\" { escaped = true }
                else if c == q {
                    if !triple { quote = nil }
                    else if index + 2 < chars.count, chars[index + 1] == q, chars[index + 2] == q {
                        quote = nil
                        index += 2
                    }
                }
            } else if c == "\"" || c == "'" {
                quote = c
                triple = index + 2 < chars.count && chars[index + 1] == c && chars[index + 2] == c
                if triple { index += 2 }
            } else if c == "#" { comment = true }
            else if c == "[" || c == "{" { depth += 1 }
            else if c == "]" || c == "}" { depth -= 1 }
            if c.isNewline, quote == nil, depth == 0 {
                ranges.append(start..<index)
                start = index + 1
            }
            index += 1
        }
        guard quote == nil, depth == 0 else { throw ConfigError("Unfinished TOML value; edit the config file to repair it") }
        if start < chars.count { ranges.append(start..<chars.count) }
        return ranges
    }

    /// Keep trailing comments and whitespace outside the replaced literal.
    private func valueEnd(_ chars: [Character], from start: Int, through end: Int) throws -> Int {
        var index = start
        var quote: Character?
        var escaped = false
        var depth = 0
        var lastValueEnd = start
        while index < end {
            let c = chars[index]
            if let q = quote {
                if escaped { escaped = false }
                else if q == "\"", c == "\\" { escaped = true }
                else if c == q { quote = nil }
                lastValueEnd = index + 1
            } else if c == "\"" || c == "'" {
                if index + 2 < end, chars[index + 1] == c, chars[index + 2] == c {
                    throw ConfigError("Multiline strings must be edited in the config file")
                }
                quote = c
                lastValueEnd = index + 1
            } else if c == "#" {
                if depth == 0 { return lastValueEnd }
                while index < end, !chars[index].isNewline { index += 1 }
                continue
            } else {
                if c == "[" || c == "{" { depth += 1 }
                if c == "]" || c == "}" { depth -= 1 }
                if !c.isWhitespace { lastValueEnd = index + 1 }
            }
            index += 1
        }
        return lastValueEnd
    }
}
