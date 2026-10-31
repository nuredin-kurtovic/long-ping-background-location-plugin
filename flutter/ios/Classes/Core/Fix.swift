import Foundation

/// One position from the OS, already in contract units.
struct Fix: Equatable {
    var latitude: Double
    var longitude: Double
    /// Horizontal accuracy, meters.
    var accuracy: Double
    /// m/s; negative = unknown.
    var speed: Double = -1
    /// Degrees; negative = unknown.
    var heading: Double = -1
    /// Meters; nil = unknown.
    var altitude: Double?
    var time: EpochMs
    var isMock = false

    var hasKnownSpeed: Bool { speed >= 0 }

    func distance(to other: Fix) -> Double {
        Geo.distance(latitude, longitude, other.latitude, other.longitude)
    }

    /// Compact form persisted for `anchor` / `parkedAt`.
    var json: JSONValue {
        var o = JSONObject()
        o["latitude"] = .number(latitude)
        o["longitude"] = .number(longitude)
        o["accuracy"] = .number(accuracy)
        o["speed"] = .number(speed)
        o["heading"] = .number(heading)
        o["altitude"] = altitude.map(JSONValue.number) ?? .null
        o["time"] = .number(Double(time))
        o["mock"] = .bool(isMock)
        return .object(o)
    }

    init(latitude: Double, longitude: Double, accuracy: Double, speed: Double = -1, heading: Double = -1,
         altitude: Double? = nil, time: EpochMs, isMock: Bool = false) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.speed = speed
        self.heading = heading
        self.altitude = altitude
        self.time = time
        self.isMock = isMock
    }

    init?(json: JSONValue) {
        guard let lat = json["latitude"]?.numberValue, let lon = json["longitude"]?.numberValue,
              let acc = json["accuracy"]?.numberValue, let time = EpochMs.timestamp(json["time"]?.numberValue),
              lat.isFinite, lon.isFinite, acc.isFinite else { return nil }
        self.init(
            latitude: lat, longitude: lon, accuracy: acc,
            speed: json["speed"]?.numberValue ?? -1,
            heading: json["heading"]?.numberValue ?? -1,
            altitude: json["altitude"]?.numberValue,
            time: time,
            isMock: json["mock"]?.boolValue ?? false
        )
    }
}

enum Geo {
    static let earthRadiusM = 6_371_008.8

    /// Haversine great-circle distance in meters.
    static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let toRad = Double.pi / 180
        let dLat = (lat2 - lat1) * toRad
        let dLon = (lon2 - lon1) * toRad
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * toRad) * cos(lat2 * toRad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusM * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }
}
