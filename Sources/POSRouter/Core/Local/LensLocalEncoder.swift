import Foundation

/// Mandatory partial encoding for Deep Link values. Only structure-breaking characters are escaped;
/// everything else stays plain text. `%` must be encoded first. Matches the Android `LensLocalEncoder`.
enum LensLocalEncoder {
    static func encode(_ value: String, separator: LocalParamSeparator = .pipe) -> String {
        var encoded = value.replacingOccurrences(of: "%", with: "%25")
        encoded = encoded
            .replacingOccurrences(of: "=", with: "%3D")
            .replacingOccurrences(of: "?", with: "%3F")
            .replacingOccurrences(of: " ", with: "%20")
        switch separator {
        case .pipe: encoded = encoded.replacingOccurrences(of: "|", with: "%7C")
        case .ampersand: encoded = encoded.replacingOccurrences(of: "&", with: "%26")
        }
        return encoded
    }

    static func pair(_ key: String, _ value: String, _ separator: LocalParamSeparator) -> String {
        "\(key)=\(encode(value, separator: separator))"
    }

    static func joinPairs(_ pairs: [String], _ separator: LocalParamSeparator) -> String {
        pairs.joined(separator: String(separator.delimiter))
    }

    /// `amountCents / 100` with two decimals, locale-independent (matches Android's `Locale.US` "%.2f").
    static func formatAmountDecimal(_ amountCents: Int64) -> String {
        String(format: "%.2f", Double(amountCents) / 100.0)
    }
}
