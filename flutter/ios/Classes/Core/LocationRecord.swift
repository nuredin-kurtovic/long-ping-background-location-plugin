import Foundation

enum RecordEvent: String, CaseIterable {
    case interval, motionchange, current
}

/// The location object emitted to JS, stored in the queue and uploaded (DESIGN.md, "Location record").
struct LocationRecord: Equatable {
    var uuid: String
    var fix: Fix
    var event: RecordEvent
    var isMoving: Bool
    var battery: BatterySnapshot
    var extras: JSONObject

    init(uuid: String = LocationRecord.makeUUID(), fix: Fix, event: RecordEvent, isMoving: Bool,
         battery: BatterySnapshot, extras: JSONObject = JSONObject()) {
        self.uuid = uuid
        self.fix = fix
        self.event = event
        self.isMoving = isMoving
        self.battery = battery
        self.extras = extras
    }

    static func makeUUID() -> String { UUID().uuidString.lowercased() }

    var timestamp: String { Timestamp.iso8601(fix.time) }

    var json: JSONValue {
        var coords = JSONObject()
        coords["latitude"] = .number(fix.latitude)
        coords["longitude"] = .number(fix.longitude)
        coords["accuracy"] = .number(fix.accuracy)
        coords["speed"] = .number(fix.speed >= 0 ? fix.speed : -1)
        coords["heading"] = .number(fix.heading >= 0 ? fix.heading : -1)
        coords["altitude"] = fix.altitude.map(JSONValue.number) ?? .null

        var battery = JSONObject()
        battery["level"] = .number(Self.normalizedLevel(self.battery.level))
        battery["is_charging"] = .bool(self.battery.isCharging)

        var o = JSONObject()
        o["uuid"] = .string(uuid)
        o["timestamp"] = .string(timestamp)
        o["event"] = .string(event.rawValue)
        o["is_moving"] = .bool(isMoving)
        o["coords"] = .object(coords)
        o["battery"] = .object(battery)
        o["mock"] = .bool(fix.isMock)
        if !extras.isEmpty { o["extras"] = .object(extras) }
        return .object(o)
    }

    /// 0...1 rounded to 2 places (UIDevice reports a Float, which widens to noise like 0.8199999928); -1 unknown.
    static func normalizedLevel(_ level: Double) -> Double {
        guard level >= 0 else { return -1 }
        return (min(level, 1) * 100).rounded() / 100
    }
}

/// `http.locationTemplate` (DESIGN.md, "Upload"). Tokens are `{{name}}`; strings go in without quotes.
enum LocationTemplate {
    static let tokens: [String] = [
        "uuid", "timestamp", "event", "is_moving", "latitude", "longitude", "accuracy", "speed", "heading",
        "altitude", "battery_level", "battery_is_charging", "mock", "extras",
    ]

    /// The record used to prove a template renders JSON at configure time.
    static func sampleRecord(extras: JSONObject) -> LocationRecord {
        LocationRecord(
            uuid: "00000000-0000-4000-8000-000000000000",
            fix: Fix(latitude: 43.85, longitude: 18.41, accuracy: 4.8, speed: 12.3, heading: 181,
                     altitude: 520.4, time: 1_767_225_600_000),
            event: .interval, isMoving: true,
            battery: BatterySnapshot(level: 0.82, isCharging: false), extras: extras
        )
    }

    static func validate(_ template: String, extras: JSONObject) throws {
        let known = Set(tokens)
        for token in tokenNames(in: template) where !known.contains(token) {
            throw ConfigError(key: "http.locationTemplate", reason: "has unknown token {{\(token)}}")
        }
        let rendered = render(template, record: sampleRecord(extras: extras).json)
        do {
            _ = try JSONValue.parse(rendered)
        } catch {
            throw ConfigError(key: "http.locationTemplate", reason: "does not render valid JSON: \(rendered)")
        }
    }

    static func render(_ template: String, record: JSONValue) -> String {
        var out = ""
        forEachSegment(template) { segment in
            switch segment {
            case .literal(let text): out += text
            case .token(let name): out += value(of: name, in: record)
            }
        }
        return out
    }

    static func tokenNames(in template: String) -> [String] {
        var names: [String] = []
        forEachSegment(template) { if case .token(let name) = $0 { names.append(name) } }
        return names
    }

    private enum Segment {
        case literal(Substring)
        case token(String)
    }

    private static func forEachSegment(_ template: String, _ body: (Segment) -> Void) {
        var rest = template[...]
        while let open = rest.range(of: "{{") {
            guard let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) else { break }
            body(.literal(rest[rest.startIndex..<open.lowerBound]))
            body(.token(rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)))
            rest = rest[close.upperBound...]
        }
        body(.literal(rest))
    }

    /// Raw JSON text for a token. Strings are escaped but not quoted: the template author writes the quotes.
    private static func value(of token: String, in record: JSONValue) -> String {
        let v: JSONValue?
        switch token {
        case "uuid", "timestamp", "event", "is_moving", "mock": v = record[token]
        case "latitude", "longitude", "accuracy", "speed", "heading", "altitude": v = record["coords"]?[token]
        case "battery_level": v = record["battery"]?["level"]
        case "battery_is_charging": v = record["battery"]?["is_charging"]
        case "extras": v = record["extras"] ?? .object(JSONObject())
        default: v = nil
        }
        switch v ?? .null {
        case .string(let s): return JSONValue.escaped(s)
        case let other: return other.serialized()
        }
    }
}

/// Request bodies (DESIGN.md, "Upload → Body").
enum UploadBody {
    struct Item: Equatable {
        var value: JSONValue
        /// Set when the template failed for this record and the plain record was sent instead.
        var templateError: String?
    }

    /// What one stored record becomes in a request. nil = the stored JSON is unreadable.
    static func item(fromStored stored: String, http: HTTPConfig) -> Item? {
        guard let record = try? JSONValue.parse(stored), record.objectValue != nil else { return nil }
        guard let template = http.locationTemplate else { return Item(value: record) }
        let rendered = LocationTemplate.render(template, record: record)
        if let value = try? JSONValue.parse(rendered) { return Item(value: value) }
        return Item(value: record, templateError: "template rendered invalid JSON for \(record["uuid"]?.stringValue ?? "?")")
    }

    /// `{ ...params, [rootProperty ?? 'locations']: [r1, r2, …] }`
    static func batch(_ items: [JSONValue], http: HTTPConfig) -> JSONValue {
        var body = http.params
        let root = http.rootProperty.flatMap { $0 == "." ? nil : $0 } ?? "locations"
        body[root] = .array(items)
        return .object(body)
    }

    /// `rootProperty == '.'` → `{ ...params, ...r }`; else `{ ...params, [rootProperty ?? 'location']: r }`.
    static func single(_ item: JSONValue, http: HTTPConfig) -> JSONValue {
        var body = http.params
        if http.rootProperty == ".", let object = item.objectValue {
            return .object(body.merging(object))
        }
        let root = http.rootProperty.flatMap { $0 == "." ? nil : $0 } ?? "location"
        body[root] = item
        return .object(body)
    }
}
