// File names for several pages or scales (exporting.adoc, "File names for several pages").  The
// Export sheet (IO-014) edits the pattern; exporters expand it for every file they write.

import Foundation

/// A token pattern such as `{name}-{page}`.
public struct FileNamePattern: Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    /// The default pattern, `{name}-{page}`.
    public static let standard = FileNamePattern("{name}-{page}")

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    /// Whether the pattern tells pages apart (`{page}`, `{page:N}` or `{pagename}`).
    public var distinguishesPages: Bool {
        rawValue.contains("{page}") || rawValue.contains("{pagename}") || rawValue.range(of: #"\{page:\d+\}"#, options: .regularExpression) != nil
    }

    /// The values the tokens take for one file.
    public struct Values: Sendable {
        public var name: String
        /// 1-based.
        public var page: Int
        public var pageName: String?
        /// 1, 2, 3: `{scale}` is empty at 1× and `@2x`, `@3x` otherwise.
        public var scale: Double
        public var date: Date

        public init(name: String, page: Int = 1, pageName: String? = nil, scale: Double = 1, date: Date = Date()) {
            self.name = name
            self.page = page
            self.pageName = pageName
            self.scale = scale
            self.date = date
        }
    }

    /// The pattern with every token replaced; unknown tokens stay as typed.
    public func expand(_ values: Values) -> String {
        var result = ""
        var rest = Substring(rawValue)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else {
                return result + rest[open...]
            }
            let token = rest[rest.index(after: open)..<close]
            result += replacement(for: token, values) ?? "{\(token)}"
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }

    private func replacement(for token: Substring, _ values: Values) -> String? {
        switch token {
        case "name":
            return values.name
        case "page":
            return String(values.page)
        case "pagename":
            let name = values.pageName ?? ""
            return name.isEmpty ? String(values.page) : name
        case "scale":
            return FileNamePattern.scaleSuffix(values.scale)
        case "date":
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: values.date)
        default:
            guard token.hasPrefix("page:"), let digits = Int(token.dropFirst(5)), digits > 0, digits <= 9 else {
                return nil
            }
            let number = String(values.page)
            return String(repeating: "0", count: max(digits - number.count, 0)) + number
        }
    }

    /// `@2x` for 2, `@1.5x` for 1.5, empty for 1.
    public static func scaleSuffix(_ scale: Double) -> String {
        guard scale != 1 else {
            return ""
        }
        let rounded = scale.rounded()
        return rounded == scale ? "@\(Int(rounded))x" : "@\(scale)x"
    }

    /// Unique file URLs for `names` (without extension) in `directory`: a name the set uses
    /// twice (two pages with one name, a token-less pattern) gets `-2`, `-3`… rather than
    /// overwriting its sibling.
    public static func uniqueURLs(for names: [String], extension fileExtension: String, in directory: URL) -> [URL] {
        var used = Set<String>()
        return names.map { name in
            var candidate = name
            var suffix = 2
            while used.contains(candidate) {
                candidate = "\(name)-\(suffix)"
                suffix += 1
            }
            used.insert(candidate)
            return directory.appendingPathComponent(candidate).appendingPathExtension(fileExtension)
        }
    }
}
