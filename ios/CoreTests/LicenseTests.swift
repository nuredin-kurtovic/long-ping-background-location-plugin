import XCTest
@testable import LongPingCore

final class LicenseTests: XCTestCase {
    private static let appId = "com.example.app"

    /// Keys signed with the real Long Ping private key (the public key is embedded in `LicenseVerifier`).
    /// TAMPERED is VALID_2030 with the last signature character changed.
    private static let vectors: [String: String] = [
        "VALID_2030": "LP1.eyJ2IjoxLCJzdWIiOiJ0ZXN0IiwiYXBwcyI6WyJjb20uZXhhbXBsZS5hcHAiXSwicGxhbiI6InBybyIsInVwZCI6IjIwMzAtMDEtMDEifQ.MEQCIDdXjyLfR51DvTPYWtgse-poKG6BXrl7gX4HtXV2sWX2AiBKeff7IVf5wI_fTHFmrV0lCDlSz5J_YBZzTyUkJkO6Lg",
        "UPD_2026_01_01": "LP1.eyJ2IjoxLCJzdWIiOiJ0ZXN0IiwiYXBwcyI6WyJjb20uZXhhbXBsZS5hcHAiXSwicGxhbiI6InBybyIsInVwZCI6IjIwMjYtMDEtMDEifQ.MEUCIDW2PMDsQuTIbW4E8ET1n2S7Mvh3Qeg_NqZsCazx9lwHAiEA9EBqEf5MR0HBZsYgWv1GNtGbdRW0LojrasnfPc2mSjI",
        "TAMPERED": "LP1.eyJ2IjoxLCJzdWIiOiJ0ZXN0IiwiYXBwcyI6WyJjb20uZXhhbXBsZS5hcHAiXSwicGxhbiI6InBybyIsInVwZCI6IjIwMzAtMDEtMDEifQ.MEQCIDdXjyLfR51DvTPYWtgse-poKG6BXrl7gX4HtXV2sWX2AiBKeff7IVf5wI_fTHFmrV0lCDlSz5J_YBZzTyUkJkO6LA",
    ]

    /// As the website's checkout issues it (openssl, no update date): apps com.example.app + com.example.app.android.
    private static let shopKey = "LP1.eyJ2IjoxLCJzdWIiOiJwYXlwYWw6VEVTVE9SREVSMTIzIiwiYXBwcyI6WyJjb20uZXhhbXBsZS5hcHAiLCJjb20uZXhhbXBsZS5hcHAuYW5kcm9pZCJdLCJwbGFuIjoiYXBwIn0.MEQCIAFYT7ksvG3WhJWy45xMvln4Hdi_Gz1kTz7JG09Rua99AiBmlaVDaXRceLxvef9Vs9j0wRx3aZk8rPhOfTV--OSKBw"

    func testKeyIssuedByTheCheckoutCoversBothItsAppsAndNothingElse() {
        for id in ["com.example.app", "com.example.app.android"] {
            let result = LicenseVerifier().verify(key: Self.shopKey, appId: id)
            guard case .valid(let payload) = result else { return XCTFail("expected valid for \(id), got \(result)") }
            XCTAssertEqual(payload.subject, "paypal:TESTORDER123")
            XCTAssertNil(payload.updatesUntil)
        }
        XCTAssertNotEqual(LicenseVerifier().verify(key: Self.shopKey, appId: "com.example.app.ios").status, .valid)
        XCTAssertNotEqual(LicenseVerifier().verify(key: Self.shopKey, appId: "com.example").status, .valid)
    }

    private func vector(_ name: String) throws -> String {
        try XCTUnwrap(Self.vectors[name], "missing test vector \(name)")
    }

    func testValidKeyCoveringThisRelease() throws {
        let result = LicenseVerifier().verify(key: try vector("VALID_2030"), appId: Self.appId)
        guard case .valid(let payload) = result else { return XCTFail("expected valid, got \(result)") }
        XCTAssertEqual(payload.version, 1)
        XCTAssertEqual(payload.subject, "test")
        XCTAssertEqual(payload.apps, ["com.example.app"])
        XCTAssertEqual(payload.plan, "pro")
        XCTAssertEqual(payload.updatesUntil, "2030-01-01")
        XCTAssertEqual(result.status, .valid)
    }

    func testKeyWhoseUpdatesEndedBeforeThisRelease() throws {
        XCTAssertEqual(LicenseVerifier.pluginReleaseDate, "2026-10-28")
        let result = LicenseVerifier().verify(key: try vector("UPD_2026_01_01"), appId: Self.appId)
        XCTAssertEqual(result, .invalid(.releaseNotCovered(updatesUntil: "2026-01-01")))
        XCTAssertEqual(result.status, .invalid)
    }

    func testTamperedSignature() throws {
        XCTAssertEqual(LicenseVerifier().verify(key: try vector("TAMPERED"), appId: Self.appId), .invalid(.badSignature))
    }

    func testUpdatesUntilIsInclusive() throws {
        let key = try vector("VALID_2030")
        XCTAssertEqual(LicenseVerifier(releaseDate: "2030-01-01").verify(key: key, appId: Self.appId).status, .valid)
        XCTAssertEqual(LicenseVerifier(releaseDate: "2030-01-02").verify(key: key, appId: Self.appId),
                       .invalid(.releaseNotCovered(updatesUntil: "2030-01-01")))
    }

    func testWrongApp() throws {
        XCTAssertEqual(LicenseVerifier().verify(key: try vector("VALID_2030"), appId: "com.example.other"),
                       .invalid(.appNotCovered("com.example.other")))
    }

    func testMissingAndMalformedKeys() throws {
        let verifier = LicenseVerifier()
        XCTAssertEqual(verifier.verify(key: nil, appId: Self.appId), .missing)
        XCTAssertEqual(verifier.verify(key: "  ", appId: Self.appId), .missing)
        XCTAssertEqual(verifier.verify(key: "LP2.abc.def", appId: Self.appId), .invalid(.malformed))
        XCTAssertEqual(verifier.verify(key: "LP1.abc", appId: Self.appId), .invalid(.malformed))
        XCTAssertEqual(verifier.verify(key: "LP1.a+b.c", appId: Self.appId), .invalid(.malformed))
        XCTAssertEqual(verifier.verify(key: "LP1..sig", appId: Self.appId), .invalid(.malformed))
        // A valid payload with a garbage signature never reaches the payload checks.
        let parts = try vector("VALID_2030").split(separator: ".")
        XCTAssertEqual(verifier.verify(key: "LP1.\(parts[1]).AAAA", appId: Self.appId), .invalid(.badSignature))
        // Whitespace around a pasted key is tolerated.
        XCTAssertEqual(verifier.verify(key: "\n\(try vector("VALID_2030")) ", appId: Self.appId).status, .valid)
    }

    func testWrongPublicKeyRejects() throws {
        var verifier = LicenseVerifier()
        verifier.publicKeyDER = Data([0x30, 0x00])
        XCTAssertEqual(verifier.verify(key: try vector("VALID_2030"), appId: Self.appId), .invalid(.badSignature))
    }

    func testAppMatching() {
        XCTAssertTrue(LicenseVerifier.appMatches(["com.bhx"], appId: "com.bhx"))
        XCTAssertFalse(LicenseVerifier.appMatches(["com.bhx"], appId: "com.bhx.driver"))
        XCTAssertTrue(LicenseVerifier.appMatches(["com.bhx.*"], appId: "com.bhx.driver"))
        XCTAssertTrue(LicenseVerifier.appMatches(["com.bhx.*"], appId: "com.bhx.driver.beta"))
        XCTAssertFalse(LicenseVerifier.appMatches(["com.bhx.*"], appId: "com.bhx"), "prefix pattern needs a segment after the dot")
        XCTAssertFalse(LicenseVerifier.appMatches(["com.bhx.*"], appId: "com.bhxpress"))
        XCTAssertTrue(LicenseVerifier.appMatches(["com.other", "com.bhx", "com.bhx.*"], appId: "com.bhx"))
        XCTAssertFalse(LicenseVerifier.appMatches([], appId: "com.bhx"))
    }

    func testBase64URL() {
        XCTAssertEqual(LicenseVerifier.base64URLDecode("eyJ2IjoxfQ"), Data("{\"v\":1}".utf8))
        XCTAssertEqual(LicenseVerifier.base64URLDecode("-_8"), Data([0xFB, 0xFF]))
        XCTAssertNil(LicenseVerifier.base64URLDecode("abc="))
        XCTAssertNil(LicenseVerifier.base64URLDecode("a"))
        XCTAssertNil(LicenseVerifier.base64URLDecode(""))
    }
}
