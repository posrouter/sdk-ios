import Foundation

/// Minimal hand-rolled JSON helpers matching the Android SDK's wire encoder/decoder byte-for-byte.
/// The Lensing wire format is parsed field-by-field (regex) on every peer, so key order is not
/// significant — but escaping and numeric/string typing must match exactly for interop.
enum WireJSON {
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// `"key":"<escaped>"`
    static func stringField(_ key: String, _ value: String) -> String {
        "\"\(key)\":\"\(escape(value))\""
    }

    static func object(_ fields: [String]) -> String {
        "{\(fields.joined(separator: ","))}"
    }

    static func extractString(_ json: String, _ key: String) -> String? {
        firstGroup(json, pattern: "\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*:\\s*\"([^\"]*)\"")
    }

    static func extractLong(_ json: String, _ key: String) -> Int64? {
        guard let raw = firstGroup(json, pattern: "\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*:\\s*(\\d+)") else {
            return nil
        }
        return Int64(raw)
    }

    /// Brace-balanced extraction of a nested `"metadata":{...}` object into flat string pairs.
    static func extractMetadata(_ json: String) -> [String: String] {
        guard let keyRange = json.range(of: "\"metadata\"") else { return [:] }
        guard let braceStart = json.range(of: "{", range: keyRange.upperBound..<json.endIndex)?.lowerBound else {
            return [:]
        }
        var depth = 0
        var idx = braceStart
        while idx < json.endIndex {
            let ch = json[idx]
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    let body = String(json[json.index(after: braceStart)..<idx])
                    return parsePairs(body)
                }
            }
            idx = json.index(after: idx)
        }
        return [:]
    }

    private static func parsePairs(_ body: String) -> [String: String] {
        var out: [String: String] = [:]
        let pattern = "\"([^\"]+)\"\\s*:\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return out }
        let ns = body as NSString
        for match in regex.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            if match.numberOfRanges == 3 {
                let k = ns.substring(with: match.range(at: 1))
                let v = ns.substring(with: match.range(at: 2))
                out[k] = v
            }
        }
        return out
    }

    private static func firstGroup(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }
}

/// Current epoch milliseconds (matches Android `System.currentTimeMillis()`).
func nowMillis() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}
