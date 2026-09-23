import Foundation

/// An sRGB colour with straight alpha, components in 0...1: guide, grid and smart-guide colours.
/// The `PreferenceValue.color_value` case of `account.v1` carries the same four components.
struct PreferenceColor: Hashable, Sendable, Codable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    static let cyan = PreferenceColor(red: 0, green: 1, blue: 1)
    static let magenta = PreferenceColor(red: 1, green: 0, blue: 1)
    static let lightGray = PreferenceColor(red: 0.8, green: 0.8, blue: 0.8)

    /// The four components, as `UserDefaults` stores them.
    var components: [Double] { [red, green, blue, alpha] }

    init?(components: [Double]) {
        guard components.count == 4 else { return nil }
        self.init(red: components[0], green: components[1], blue: components[2], alpha: components[3])
    }
}

/// One stored preference value.  Mirrors the `oneof` of `account.v1.PreferenceValue`
/// (preferences.adoc, "Data model") so the synced map can carry any catalog entry.
enum PreferenceValue: Hashable, Sendable, Codable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case color(PreferenceColor)
    case list([String])

    /// The property-list object `UserDefaults` stores.
    var propertyList: Any {
        switch self {
        case let .bool(value): value
        case let .int(value): value
        case let .double(value): value
        case let .string(value): value
        case let .color(value): value.components
        case let .list(value): value
        }
    }

    /// Reads a property-list object back as the same case as `template` (the key's default),
    /// or `nil` when the stored object has the wrong type.  `UserDefaults` bridges numbers
    /// through `NSNumber`, so an `Int` stored for a `Double` key reads back as that `Double`.
    init?(propertyList object: Any, like template: PreferenceValue) {
        switch template {
        case .bool:
            guard let number = object as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            self = .bool(number.boolValue)
        case .int:
            guard let number = object as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                let value = Int(exactly: number.doubleValue)
            else { return nil }
            self = .int(value)
        case .double:
            guard let number = object as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            self = .double(number.doubleValue)
        case .string:
            guard let value = object as? String else { return nil }
            self = .string(value)
        case .color:
            guard let components = object as? [Double], let color = PreferenceColor(components: components) else { return nil }
            self = .color(color)
        case .list:
            guard let value = object as? [String] else { return nil }
            self = .list(value)
        }
    }

    /// Whether `other` is the same case, so a write cannot change a key's type.
    func hasSameType(as other: PreferenceValue) -> Bool {
        switch (self, other) {
        case (.bool, .bool), (.int, .int), (.double, .double), (.string, .string), (.color, .color), (.list, .list):
            true
        default:
            false
        }
    }

    /// The numeric value, for range checks.
    var number: Double? {
        switch self {
        case let .int(value): Double(value)
        case let .double(value): value
        default: nil
        }
    }
}

/// A Swift type a `PreferenceKey` can hold.
protocol PreferenceValueConvertible: Hashable, Sendable {
    init?(preferenceValue: PreferenceValue)
    var preferenceValue: PreferenceValue { get }
}

extension Bool: PreferenceValueConvertible {
    init?(preferenceValue: PreferenceValue) {
        guard case let .bool(value) = preferenceValue else { return nil }
        self = value
    }

    var preferenceValue: PreferenceValue { .bool(self) }
}

extension Int: PreferenceValueConvertible {
    init?(preferenceValue: PreferenceValue) {
        guard case let .int(value) = preferenceValue else { return nil }
        self = value
    }

    var preferenceValue: PreferenceValue { .int(self) }
}

extension Double: PreferenceValueConvertible {
    init?(preferenceValue: PreferenceValue) {
        guard case let .double(value) = preferenceValue else { return nil }
        self = value
    }

    var preferenceValue: PreferenceValue { .double(self) }
}

extension String: PreferenceValueConvertible {
    init?(preferenceValue: PreferenceValue) {
        guard case let .string(value) = preferenceValue else { return nil }
        self = value
    }

    var preferenceValue: PreferenceValue { .string(self) }
}

extension PreferenceColor: PreferenceValueConvertible {
    init?(preferenceValue: PreferenceValue) {
        guard case let .color(value) = preferenceValue else { return nil }
        self = value
    }

    var preferenceValue: PreferenceValue { .color(self) }
}

extension Array: PreferenceValueConvertible where Element == String {
    init?(preferenceValue: PreferenceValue) {
        guard case let .list(value) = preferenceValue else { return nil }
        self = value
    }

    var preferenceValue: PreferenceValue { .list(self) }
}
