import Foundation

/// A JSON value with insertion-ordered objects and deterministic serialization.
///
/// Config, records and upload bodies all flow through this type so that the bytes we store and send
/// do not depend on `JSONSerialization` quirks (number formatting, key order, `NSNumber` booleans).
enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

/// String-keyed JSON object that remembers insertion order. Equality ignores order.
struct JSONObject: Equatable, Sequence {
    private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    init() {}

    init(_ pairs: [(String, JSONValue)]) {
        for (key, value) in pairs { self[key] = value }
    }

    subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    var count: Int { keys.count }
    var isEmpty: Bool { keys.isEmpty }

    func makeIterator() -> AnyIterator<(key: String, value: JSONValue)> {
        var index = 0
        return AnyIterator {
            guard index < keys.count else { return nil }
            defer { index += 1 }
            let key = keys[index]
            return (key, storage[key] ?? .null)
        }
    }

    /// Shallow merge: keys from `other` win and keep this object's order for existing keys.
    func merging(_ other: JSONObject) -> JSONObject {
        var result = self
        for (key, value) in other { result[key] = value }
        return result
    }

    static func == (lhs: JSONObject, rhs: JSONObject) -> Bool { lhs.storage == rhs.storage }
}

// MARK: - Accessors

extension JSONValue {
    var objectValue: JSONObject? { if case .object(let o) = self { return o } else { return nil } }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    var numberValue: Double? { if case .number(let n) = self { return n } else { return nil } }
    var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    var isNull: Bool { self == .null }

    subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// Objects merge recursively; arrays and scalars in `patch` replace.
    func deepMerged(with patch: JSONValue) -> JSONValue {
        guard case .object(let base) = self, case .object(let overlay) = patch else { return patch }
        var result = base
        for (key, value) in overlay {
            if let existing = result[key], existing.objectValue != nil, value.objectValue != nil {
                result[key] = existing.deepMerged(with: value)
            } else {
                result[key] = value
            }
        }
        return .object(result)
    }
}

// MARK: - Serialization

extension JSONValue {
    func serialized() -> String {
        var out = ""
        write(to: &out)
        return out
    }

    var data: Data { Data(serialized().utf8) }

    private func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += JSONValue.format(n)
        case .string(let s): JSONValue.writeQuoted(s, to: &out)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                item.write(to: &out)
            }
            out += "]"
        case .object(let object):
            out += "{"
            var first = true
            for (key, value) in object {
                if !first { out += "," }
                first = false
                JSONValue.writeQuoted(key, to: &out)
                out += ":"
                value.write(to: &out)
            }
            out += "}"
        }
    }

    /// Shortest round-trip representation; integral values print without a fraction.
    static func format(_ n: Double) -> String {
        guard n.isFinite else { return "null" }
        if n == n.rounded(), abs(n) < 1e15 {
            return String(Int64(n))
        }
        return "\(n)"
    }

    /// JSON string contents without the surrounding quotes.
    static func escaped(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    private static func writeQuoted(_ s: String, to out: inout String) {
        out += "\""
        out += escaped(s)
        out += "\""
    }
}

// MARK: - Parsing and Foundation bridging

enum JSONParseError: Error, Equatable {
    case invalid(String)
}

extension JSONValue {
    static func parse(_ text: String) throws -> JSONValue {
        try parse(data: Data(text.utf8))
    }

    static func parse(data: Data) throws -> JSONValue {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw JSONParseError.invalid((error as NSError).localizedDescription)
        }
        guard let value = JSONValue(foundation: object) else {
            throw JSONParseError.invalid("unsupported value")
        }
        return value
    }

    /// Converts the Foundation graph React Native and JSONSerialization produce. Dictionary keys are
    /// sorted because NSDictionary has no order. Returns nil for values JSON cannot carry.
    init?(foundation value: Any?) {
        guard let value else { self = .null; return }
        switch value {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            // NSNumber hides booleans; CFBoolean is the only reliable tell on Darwin.
            if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            var items: [JSONValue] = []
            items.reserveCapacity(array.count)
            for element in array {
                guard let item = JSONValue(foundation: element) else { return nil }
                items.append(item)
            }
            self = .array(items)
        case let dictionary as [String: Any]:
            var object = JSONObject()
            for key in dictionary.keys.sorted() {
                guard let item = JSONValue(foundation: dictionary[key]) else { return nil }
                object[key] = item
            }
            self = .object(object)
        default:
            return nil
        }
    }

    /// NSNull / NSNumber / NSString / NSArray / NSDictionary, ready for the React Native bridge.
    var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return NSNumber(value: b)
        case .number(let n): return NSNumber(value: n)
        case .string(let s): return s
        case .array(let items): return items.map { $0.foundationObject }
        case .object(let object):
            var dictionary: [String: Any] = [:]
            for (key, value) in object { dictionary[key] = value.foundationObject }
            return dictionary
        }
    }
}

// No ExpressibleByNilLiteral: it would silently turn `nil` in `JSONValue?` closures into `.null`.
extension JSONValue: ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral {
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(stringLiteral value: String) { self = .string(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(JSONObject(elements)) }
}
