import CryptoKit
import Foundation

enum LicenseStatus: String {
    case valid, debug, invalid, missing
}

/// Offline license check (DESIGN.md, "License"). Key: `LP1.<payload>.<signature>`, base64url, ECDSA P-256 /
/// SHA-256 over the ASCII bytes of `LP1.<payload>`.
struct LicenseVerifier {
    /// This plugin build's release date. A key covers every release up to its `upd` (inclusive).
    static let pluginReleaseDate = "2026-10-28"

    static let publicKeySPKIBase64 =
        "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEfz4a/OgAm9wr//FwRGIEJr+t4l2Mbj7E7b0jaVLwb0x+f+YUg6XZCBmzW6x2zF9sy4yVqBKSj8v0dt9lC9xLhQ=="

    struct Payload: Equatable {
        var version: Int
        var subject: String?
        var apps: [String]
        var plan: String?
        var updatesUntil: String?
    }

    enum Failure: Equatable, CustomStringConvertible {
        case malformed
        case badSignature
        case unsupportedVersion(Int)
        case appNotCovered(String)
        case releaseNotCovered(updatesUntil: String)

        var description: String {
            switch self {
            case .malformed: return "key is malformed"
            case .badSignature: return "signature does not verify"
            case .unsupportedVersion(let v): return "unsupported key version \(v)"
            case .appNotCovered(let app): return "app id \(app) is not covered by this key"
            case .releaseNotCovered(let upd):
                return "key covers releases until \(upd); this plugin release is \(LicenseVerifier.pluginReleaseDate)"
            }
        }
    }

    enum Result: Equatable {
        case valid(Payload)
        case missing
        case invalid(Failure)

        var status: LicenseStatus {
            switch self {
            case .valid: return .valid
            case .missing: return .missing
            case .invalid: return .invalid
            }
        }
    }

    var releaseDate = LicenseVerifier.pluginReleaseDate
    var publicKeyDER: Data? = Data(base64Encoded: LicenseVerifier.publicKeySPKIBase64)

    func verify(key rawKey: String?, appId: String) -> Result {
        guard let key = rawKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return .missing }
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "LP1",
              let payloadData = Self.base64URLDecode(String(parts[1])),
              let signatureData = Self.base64URLDecode(String(parts[2])) else {
            return .invalid(.malformed)
        }

        guard let der = publicKeyDER,
              let publicKey = try? P256.Signing.PublicKey(derRepresentation: der),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData) else {
            return .invalid(.badSignature)
        }
        let digest = SHA256.hash(data: Data("\(parts[0]).\(parts[1])".utf8))
        guard publicKey.isValidSignature(signature, for: digest) else { return .invalid(.badSignature) }

        guard let payload = Self.parsePayload(payloadData) else { return .invalid(.malformed) }
        guard payload.version == 1 else { return .invalid(.unsupportedVersion(payload.version)) }
        guard Self.appMatches(payload.apps, appId: appId) else { return .invalid(.appNotCovered(appId)) }
        if let upd = payload.updatesUntil {
            guard Self.isISODate(upd) else { return .invalid(.malformed) }
            // YYYY-MM-DD strings order the same as the dates they name.
            guard releaseDate <= upd else { return .invalid(.releaseNotCovered(updatesUntil: upd)) }
        }
        return .valid(payload)
    }

    /// Exact id, or a prefix pattern ending in `.*` (`com.acme.*` covers `com.acme.driver`, not `com.acme`).
    static func appMatches(_ patterns: [String], appId: String) -> Bool {
        patterns.contains { pattern in
            if pattern.hasSuffix(".*") { return appId.hasPrefix(String(pattern.dropLast())) }
            return pattern == appId
        }
    }

    static func base64URLDecode(_ s: String) -> Data? {
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return nil
        }
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = b64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { b64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: b64)
    }

    private static func parsePayload(_ data: Data) -> Payload? {
        guard let json = try? JSONValue.parse(data: data), json.objectValue != nil,
              let version = json["v"]?.numberValue, version == version.rounded(), abs(version) < 1e9 else { return nil }
        let apps = json["apps"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        let upd: String?
        switch json["upd"] {
        case .none, .some(.null): upd = nil
        case .some(.string(let s)): upd = s
        default: return nil
        }
        return Payload(version: Int(version), subject: json["sub"]?.stringValue, apps: apps,
                       plan: json["plan"]?.stringValue, updatesUntil: upd)
    }

    private static func isISODate(_ s: String) -> Bool {
        let chars = Array(s)
        guard chars.count == 10, chars[4] == "-", chars[7] == "-" else { return false }
        return chars.enumerated().allSatisfy { index, c in index == 4 || index == 7 || c.isASCII && c.isNumber }
    }
}
