import Foundation

/// What to do after one upload attempt (DESIGN.md, "Upload → Response handling").
enum UploadAction: Equatable {
    /// 2xx: delete the sent records, reset backoff, read `long_ping`.
    case deleteSent
    /// 401/403 with a refresh URL not yet tried in this run: refresh, then retry the batch once.
    case refreshAndRetry
    /// 401/403 otherwise: `authorizationRequired`, keep records, pause uploads.
    case pauseForAuthorization
    /// 413: retry immediately with this many records.
    case retrySmaller(limit: Int)
    /// 408, 429, 5xx, network error, timeout: keep records, back off.
    case backoff
    /// Other 4xx: `attempts += 1`; records reaching `maxAttempts` are dropped.
    case countAttempt
}

enum UploadPolicy {
    static let maxAttempts = 3
    static let authPauseMs: EpochMs = 15 * 60_000
    static let maxBackoffSec = 900.0
    static let baseBackoffSec = 10.0
    static let jitter = 0.2
    /// Upper bound for a server's Retry-After so a bad header cannot stall uploads indefinitely.
    static let maxRetryAfterSec = 86_400.0
    /// `http` events carry this much of the response body.
    static let responseTextLimit = 2048

    /// `status` 0 = network error / timeout.
    static func action(status: Int, sentCount: Int, refreshAvailable: Bool, alreadyRefreshed: Bool) -> UploadAction {
        switch status {
        case 200...299:
            return .deleteSent
        case 401, 403:
            return refreshAvailable && !alreadyRefreshed ? .refreshAndRetry : .pauseForAuthorization
        case 413:
            return sentCount > 1 ? .retrySmaller(limit: max(1, sentCount / 2)) : .countAttempt
        case 408, 429, 500...599, 0:
            return .backoff
        case 400...499:
            return .countAttempt
        default:
            // 1xx/3xx that URLSession did not resolve, or nonsense codes: transient, keep the records.
            return .backoff
        }
    }

    /// `min(900, 10 × 2^n)` seconds with ±20 % jitter. `failures` = consecutive failures before this one;
    /// `random` returns a value in 0..<1.
    static func backoffSec(failures: Int, random: () -> Double) -> Double {
        let exponent = Double(min(max(failures, 0), 16))
        let base = min(maxBackoffSec, baseBackoffSec * pow(2, exponent))
        let factor = 1 - jitter + 2 * jitter * min(max(random(), 0), 1)
        return base * factor
    }

    /// Delta-seconds or HTTP-date. nil when absent or unreadable.
    static func retryAfterSec(_ header: String?, now: EpochMs) -> Double? {
        guard let raw = header?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = Double(raw), seconds.isFinite {
            return min(max(seconds, 0), maxRetryAfterSec)
        }
        guard let date = httpDateFormatter.date(from: raw) else { return nil }
        let delta = date.timeIntervalSince1970 - Double(now) / 1000
        return min(max(delta, 0), maxRetryAfterSec)
    }

    private static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    static func responseText(_ data: Data?) -> String {
        guard let data, !data.isEmpty else { return "" }
        let prefix = data.prefix(responseTextLimit)
        // A 2 KB cut can split a UTF-8 sequence; fall back to a lossy decode instead of dropping the text.
        return String(data: prefix, encoding: .utf8) ?? String(decoding: prefix, as: UTF8.self)
    }
}

/// Why an upload is being considered.
enum UploadTrigger: String {
    case recordInserted, connectivity, sync, authorization, watchdog, retryTimer
}

/// When uploads may run: backoff, `uploadIntervalSec`, and the auth pause.
struct UploadScheduler: Equatable {
    private(set) var consecutiveFailures = 0
    /// Backoff gate (0 = none).
    private(set) var backoffUntil: EpochMs = 0
    private(set) var lastAttemptAt: EpochMs?
    /// Set after an unrecoverable 401/403; uploads resume after it or on new credentials.
    private(set) var authPausedUntil: EpochMs?
    private(set) var lastFailureWasNetwork = false

    func shouldUpload(_ trigger: UploadTrigger, now: EpochMs, uploadIntervalSec: Double) -> Bool {
        switch trigger {
        case .sync:
            return true
        case .authorization:
            return now >= backoffUntil
        case .connectivity:
            if let paused = authPausedUntil, now < paused { return false }
            return now >= backoffUntil
        case .recordInserted, .watchdog, .retryTimer:
            if let paused = authPausedUntil, now < paused { return false }
            return now >= nextDueAt(uploadIntervalSec: uploadIntervalSec)
        }
    }

    /// Earliest time a non-forced upload may start.
    func nextDueAt(uploadIntervalSec: Double) -> EpochMs {
        var due = backoffUntil
        if uploadIntervalSec > 0, let last = lastAttemptAt {
            due = max(due, last + EpochMs(seconds: uploadIntervalSec))
        }
        if let paused = authPausedUntil { due = max(due, paused) }
        return due
    }

    mutating func attemptStarted(now: EpochMs) { lastAttemptAt = now }

    mutating func succeeded() {
        consecutiveFailures = 0
        backoffUntil = 0
        authPausedUntil = nil
        lastFailureWasNetwork = false
    }

    /// Returns the delay applied, in seconds.
    @discardableResult
    mutating func failedTransiently(now: EpochMs, status: Int, retryAfterSec: Double?, random: () -> Double) -> Double {
        let delay = retryAfterSec ?? UploadPolicy.backoffSec(failures: consecutiveFailures, random: random)
        consecutiveFailures += 1
        backoffUntil = now + EpochMs(seconds: delay)
        lastFailureWasNetwork = status == 0
        return delay
    }

    mutating func pauseForAuthorization(now: EpochMs) {
        authPausedUntil = now + UploadPolicy.authPauseMs
    }

    /// New credentials: the pause no longer applies.
    mutating func authorizationChanged() { authPausedUntil = nil }

    /// Backoff earned by "no network" is moot once the network is back; server-side backoff stays.
    mutating func connectivityRestored() {
        if lastFailureWasNetwork { backoffUntil = 0 }
    }
}

/// Stored upload credentials (secure storage; never part of config).
struct AuthCredentials: Equatable {
    var accessToken: String
    var refreshToken: String?
    var refreshUrl: String?
    var refreshPayload: [String: String]?
    var refreshHeaders: [String: String]?

    static let defaultRefreshPayload = ["refresh_token": "{{refreshToken}}"]

    init(accessToken: String, refreshToken: String? = nil, refreshUrl: String? = nil,
         refreshPayload: [String: String]? = nil, refreshHeaders: [String: String]? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.refreshUrl = refreshUrl
        self.refreshPayload = refreshPayload
        self.refreshHeaders = refreshHeaders
    }

    /// From `setAuthorization(auth)`. Throws with the offending key.
    init(json: JSONValue) throws {
        guard let o = json.objectValue else { throw ConfigError(key: "auth", reason: "must be an object") }
        guard let token = o["accessToken"]?.stringValue, !token.isEmpty else {
            throw ConfigError(key: "accessToken", reason: "must be a non-empty string")
        }
        func optionalString(_ key: String) throws -> String? {
            guard let v = o[key], !v.isNull else { return nil }
            guard let s = v.stringValue else { throw ConfigError(key: key, reason: "must be a string") }
            return s.isEmpty ? nil : s
        }
        func stringMap(_ key: String) throws -> [String: String]? {
            guard let v = o[key], !v.isNull else { return nil }
            guard let m = v.objectValue else { throw ConfigError(key: key, reason: "must be an object") }
            var out: [String: String] = [:]
            for (k, value) in m {
                guard let s = value.stringValue else { throw ConfigError(key: "\(key).\(k)", reason: "must be a string") }
                out[k] = s
            }
            return out
        }
        accessToken = token
        refreshToken = try optionalString("refreshToken")
        refreshUrl = try optionalString("refreshUrl")
        refreshPayload = try stringMap("refreshPayload")
        refreshHeaders = try stringMap("refreshHeaders")
        if let url = refreshUrl, URL(string: url)?.scheme.map({ ["http", "https"].contains($0.lowercased()) }) != true {
            throw ConfigError(key: "refreshUrl", reason: "must be an http(s) URL")
        }
    }

    var json: JSONValue {
        func map(_ m: [String: String]?) -> JSONValue {
            guard let m else { return .null }
            return .object(JSONObject(m.keys.sorted().map { ($0, JSONValue.string(m[$0] ?? "")) }))
        }
        return .object(JSONObject([
            ("accessToken", .string(accessToken)),
            ("refreshToken", refreshToken.map(JSONValue.string) ?? .null),
            ("refreshUrl", refreshUrl.map(JSONValue.string) ?? .null),
            ("refreshPayload", map(refreshPayload)),
            ("refreshHeaders", map(refreshHeaders)),
        ]))
    }

    var canRefresh: Bool { refreshUrl.flatMap(URL.init(string:)) != nil }
}

/// The 401/403 refresh exchange.
enum AuthRefresh {
    /// `refreshPayload` (default `{"refresh_token":"{{refreshToken}}"}`) with `{{refreshToken}}` replaced.
    static func body(for credentials: AuthCredentials) -> JSONValue {
        let payload = credentials.refreshPayload ?? AuthCredentials.defaultRefreshPayload
        var o = JSONObject()
        for key in payload.keys.sorted() {
            let template = payload[key] ?? ""
            o[key] = .string(template.replacingOccurrences(of: "{{refreshToken}}", with: credentials.refreshToken ?? ""))
        }
        return .object(o)
    }

    /// `access_token` | `accessToken`, and optional `refresh_token` | `refreshToken`, from the reply.
    static func tokens(from data: Data) -> (accessToken: String, refreshToken: String?)? {
        guard let json = try? JSONValue.parse(data: data) else { return nil }
        guard let access = (json["access_token"] ?? json["accessToken"])?.stringValue, !access.isEmpty else { return nil }
        let refresh = (json["refresh_token"] ?? json["refreshToken"])?.stringValue
        return (access, refresh?.isEmpty == true ? nil : refresh)
    }

    /// Credentials after a successful refresh: a new refresh token replaces the old only when one was sent.
    static func updated(_ credentials: AuthCredentials, accessToken: String, refreshToken: String?) -> AuthCredentials {
        var c = credentials
        c.accessToken = accessToken
        if let refreshToken { c.refreshToken = refreshToken }
        return c
    }
}

/// `long_ping` in a 2xx upload response.
struct RemoteCommand: Equatable {
    var config: JSONValue?
    var stop: Bool
    /// Clear the server's overrides (before `config`, when both are present).
    var reset = false

    static func parse(_ data: Data?) -> RemoteCommand? {
        guard let data, !data.isEmpty, let json = try? JSONValue.parse(data: data),
              let command = json["long_ping"]?.objectValue else { return nil }
        let config = command["config"].flatMap { $0.objectValue != nil ? $0 : nil }
        let stop = command["stop"]?.boolValue == true
        let reset = command["reset"]?.boolValue == true
        guard config != nil || stop || reset else { return nil }
        return RemoteCommand(config: config, stop: stop, reset: reset)
    }
}

/// Request headers: config headers, then `Authorization: Bearer` when credentials exist (it wins over a
/// configured Authorization header regardless of case).
enum UploadHeaders {
    static func make(configured: [String: String], accessToken: String?) -> [(String, String)] {
        var headers: [(String, String)] = [("Content-Type", "application/json"), ("Accept", "application/json")]
        for key in configured.keys.sorted() {
            let lower = key.lowercased()
            if accessToken != nil, lower == "authorization" { continue }
            if lower == "content-type" || lower == "accept" {
                headers.removeAll { $0.0.lowercased() == lower }
            }
            headers.append((key, configured[key] ?? ""))
        }
        if let token = accessToken { headers.append(("Authorization", "Bearer \(token)")) }
        return headers
    }
}
