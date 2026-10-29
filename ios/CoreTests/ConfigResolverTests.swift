import XCTest
@testable import LongPingCore

final class ConfigResolverTests: XCTestCase {
    private func resolve(_ patch: JSONValue) throws -> LongPingConfig {
        try ConfigResolver.resolve(patch).config
    }

    private func assertRejects(_ patch: JSONValue, key: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ConfigResolver.resolve(patch), file: file, line: line) { error in
            guard let configError = error as? ConfigError else {
                return XCTFail("expected ConfigError, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(configError.key, key, file: file, line: line)
            XCTAssertEqual(configError.asLongPingError.code, .invalidConfig, file: file, line: line)
            XCTAssertTrue(configError.asLongPingError.message.contains(key), file: file, line: line)
        }
    }

    func testDefaultsMatchContract() throws {
        let c = try resolve([:])
        XCTAssertEqual(c.movingIntervalSec, 30)
        XCTAssertEqual(c.parkedIntervalSec, 180)
        XCTAssertEqual(c.accuracy, .high)
        XCTAssertEqual(c.minAccuracyM, 100)
        XCTAssertEqual(c.stopTimeoutSec, 300)
        XCTAssertEqual(c.stopRadiusM, 75)
        XCTAssertEqual(c.movingSpeedMps, 3)
        XCTAssertFalse(c.disableStopDetection)
        XCTAssertNil(c.lowBattery)
        XCTAssertNil(c.http.url)
        XCTAssertEqual(c.http.method, .post)
        XCTAssertEqual(c.http.headers, [:])
        XCTAssertTrue(c.http.batch)
        XCTAssertEqual(c.http.maxBatchSize, 100)
        XCTAssertEqual(c.http.uploadIntervalSec, 0)
        XCTAssertNil(c.http.rootProperty)
        XCTAssertNil(c.http.locationTemplate)
        XCTAssertTrue(c.http.params.isEmpty)
        XCTAssertTrue(c.http.extras.isEmpty)
        XCTAssertEqual(c.http.timeoutSec, 30)
        XCTAssertEqual(c.persistence.maxRecords, 10_000)
        XCTAssertEqual(c.persistence.maxDays, 7)
        XCTAssertTrue(c.startOnBoot)
        XCTAssertFalse(c.stopOnTerminate)
        XCTAssertTrue(c.remoteConfig)
        XCTAssertEqual(c.notification.title, "Location tracking")
        XCTAssertEqual(c.notification.text, "Sharing your location")
        XCTAssertEqual(c.notification.channelName, "Location tracking")
        XCTAssertNil(c.notification.smallIcon)
        XCTAssertEqual(c.notification.priority, .low)
        XCTAssertFalse(c.ios.showsBackgroundLocationIndicator)
        XCTAssertEqual(c.ios.activityType, .automotive)
        XCTAssertEqual(c.logLevel, .info)
        XCTAssertEqual(c.logMaxDays, 3)
        XCTAssertFalse(c.debug)
        XCTAssertEqual(c, LongPingConfig.defaults)
        XCTAssertEqual(try resolve(.null), LongPingConfig.defaults)
    }

    func testJSONKeyOrderFollowsContractAndRoundTrips() throws {
        let json = LongPingConfig.defaults.json
        XCTAssertEqual(json.objectValue?.keys, [
            "movingIntervalSec", "parkedIntervalSec", "accuracy", "minAccuracyM", "stopTimeoutSec",
            "stopRadiusM", "movingSpeedMps", "disableStopDetection", "lowBattery", "http", "persistence",
            "startOnBoot", "stopOnTerminate", "remoteConfig", "notification", "ios", "logLevel", "logMaxDays", "debug",
        ])
        let custom = try resolve([
            "movingIntervalSec": 5, "lowBattery": ["belowPct": 20, "intervalSec": 600],
            "http": ["url": "https://example.com/locations", "headers": ["X-Key": "1"], "params": ["device": ["id": 7]],
                     "locationTemplate": "{\"lat\":{{latitude}}}"],
        ])
        XCTAssertEqual(try ConfigResolver.resolve(custom.json).config, custom)
        XCTAssertEqual(try JSONValue.parse(custom.json.serialized()), custom.json)
    }

    func testWrongTypesRejectWithTheKeyName() {
        assertRejects(["movingIntervalSec": "30"], key: "movingIntervalSec")
        assertRejects(["accuracy": 1], key: "accuracy")
        assertRejects(["disableStopDetection": "yes"], key: "disableStopDetection")
        assertRejects(["lowBattery": 5], key: "lowBattery")
        assertRejects(["lowBattery": ["belowPct": 20]], key: "lowBattery.intervalSec")
        assertRejects(["http": "https://x"], key: "http")
        assertRejects(["http": ["maxBatchSize": true]], key: "http.maxBatchSize")
        assertRejects(["http": ["headers": ["X-Num": 1]]], key: "http.headers.X-Num")
        assertRejects(["http": ["params": [1, 2]]], key: "http.params")
        assertRejects(["http": ["method": "GET"]], key: "http.method")
        assertRejects(["http": ["url": "ftp://example.com"]], key: "http.url")
        assertRejects(["http": ["url": "not a url"]], key: "http.url")
        assertRejects(["persistence": ["maxDays": "7"]], key: "persistence.maxDays")
        assertRejects(["notification": ["priority": "urgent"]], key: "notification.priority")
        assertRejects(["ios": ["activityType": "walking"]], key: "ios.activityType")
        assertRejects(["logLevel": "verbose"], key: "logLevel")
        assertRejects(.array([]), key: "config")
        assertRejects(["movingIntervalSec": .number(.infinity)], key: "movingIntervalSec")
    }

    func testOutOfRangeNumbersAreClampedAndNoted() throws {
        let resolution = try ConfigResolver.resolve([
            "movingIntervalSec": 0, "parkedIntervalSec": 100_000, "stopTimeoutSec": 5, "stopRadiusM": 20_000,
            "movingSpeedMps": 0.1, "minAccuracyM": -5, "logMaxDays": 90,
            "http": ["maxBatchSize": 5000, "timeoutSec": 1, "uploadIntervalSec": -1],
            "persistence": ["maxRecords": 0, "maxDays": 1000],
            "lowBattery": ["belowPct": 150, "intervalSec": 0],
        ])
        let c = resolution.config
        XCTAssertEqual(c.movingIntervalSec, 1)
        XCTAssertEqual(c.parkedIntervalSec, 86_400)
        XCTAssertEqual(c.stopTimeoutSec, 30)
        XCTAssertEqual(c.stopRadiusM, 10_000)
        XCTAssertEqual(c.movingSpeedMps, 0.5)
        XCTAssertEqual(c.minAccuracyM, 0)
        XCTAssertEqual(c.logMaxDays, 30)
        XCTAssertEqual(c.http.maxBatchSize, 1000)
        XCTAssertEqual(c.http.timeoutSec, 5)
        XCTAssertEqual(c.http.uploadIntervalSec, 0)
        XCTAssertEqual(c.persistence.maxRecords, 1)
        XCTAssertEqual(c.persistence.maxDays, 365)
        XCTAssertEqual(c.lowBattery, LowBatteryPolicy(belowPct: 100, intervalSec: 1))
        XCTAssertEqual(resolution.notes.filter { $0.kind == .clamped }.count, 14)
        XCTAssertTrue(resolution.notes.contains { $0.message == "movingIntervalSec 0 out of range, using 1" })
    }

    func testFractionalIntegersRound() throws {
        XCTAssertEqual(try resolve(["http": ["maxBatchSize": 10.6]]).http.maxBatchSize, 11)
        XCTAssertEqual(try resolve(["movingIntervalSec": 1.5]).movingIntervalSec, 1.5)
    }

    func testUnknownKeysAreIgnoredAndNoted() throws {
        let resolution = try ConfigResolver.resolve([
            "distanceFilter": 10, "http": ["autoSync": true, "headers": ["Anything": "ok"]], "ios": ["foo": 1],
        ])
        XCTAssertEqual(resolution.config, LongPingConfig.defaults.with { $0.http.headers = ["Anything": "ok"] })
        XCTAssertEqual(resolution.notes.filter { $0.kind == .unknownKey }.map(\.message),
                       ["unknown key 'distanceFilter' ignored", "unknown key 'http.autoSync' ignored",
                        "unknown key 'ios.foo' ignored"])
        XCTAssertNil(resolution.config.json["distanceFilter"])
    }

    func testNullResetsNonNullableKeysAndClearsNullableOnes() throws {
        let current = try resolve(["movingIntervalSec": 5, "lowBattery": ["belowPct": 10, "intervalSec": 600],
                                   "http": ["url": "https://x.example/a", "batch": false]])
        let next = try ConfigResolver.resolve(["movingIntervalSec": .null, "lowBattery": .null, "http": ["url": .null]],
                                              onto: current.json).config
        XCTAssertEqual(next.movingIntervalSec, 30)
        XCTAssertNil(next.lowBattery)
        XCTAssertNil(next.http.url)
        XCTAssertFalse(next.http.batch, "untouched keys survive a setConfig")
    }

    func testSetConfigDeepMergesObjectsAndReplacesArraysAndScalars() throws {
        let current = try resolve([
            "parkedIntervalSec": 600,
            "http": ["url": "https://x.example/a", "headers": ["A": "1"], "params": ["tags": ["a", "b"], "fleet": ["id": 1]]],
        ])
        let next = try ConfigResolver.resolve([
            "movingIntervalSec": 10,
            "http": ["headers": ["B": "2"], "params": ["tags": ["c"], "fleet": ["name": "x"]]],
        ], onto: current.json).config
        XCTAssertEqual(next.parkedIntervalSec, 600)
        XCTAssertEqual(next.movingIntervalSec, 10)
        XCTAssertEqual(next.http.url, "https://x.example/a")
        XCTAssertEqual(next.http.headers, ["A": "1", "B": "2"])
        XCTAssertEqual(next.http.params["tags"], ["c"])
        XCTAssertEqual(next.http.params["fleet"], ["id": 1, "name": "x"])
    }

    func testConfigureReplacesTheWholeConfig() throws {
        let current = try resolve(["parkedIntervalSec": 600])
        // configure() resolves onto defaults, never onto the current config.
        XCTAssertEqual(try ConfigResolver.resolve(["movingIntervalSec": 10]).config.parkedIntervalSec, 180)
        XCTAssertEqual(current.parkedIntervalSec, 600)
    }

    func testEmptyStringsMeanNull() throws {
        let c = try resolve(["http": ["url": "", "rootProperty": "", "locationTemplate": ""]])
        XCTAssertNil(c.http.url)
        XCTAssertNil(c.http.uploadURL)
        XCTAssertNil(c.http.rootProperty)
        XCTAssertNil(c.http.locationTemplate)
    }

    func testLicenseKeyFromOlderSetupsIsIgnored() throws {
        let resolution = try ConfigResolver.resolve(["licenseKey": "LP1.x.y"])
        XCTAssertEqual(resolution.config, LongPingConfig.defaults)
        XCTAssertEqual(resolution.notes.map(\.kind), [.unknownKey])
    }

    func testTemplateIsValidatedAtConfigureTime() throws {
        XCTAssertNoThrow(try resolve(["http": ["locationTemplate": "{\"lat\":{{latitude}},\"at\":\"{{timestamp}}\",\"x\":{{extras}}}"]]))
        assertRejects(["http": ["locationTemplate": "{\"lat\":{{lat}}}"]], key: "http.locationTemplate")
        assertRejects(["http": ["locationTemplate": "{\"at\":{{timestamp}}}"]], key: "http.locationTemplate")
        assertRejects(["http": ["locationTemplate": "{\"lat\":{{latitude}}"]], key: "http.locationTemplate")
    }

    func testDotRootPropertyWithBatchIsNoted() throws {
        let resolution = try ConfigResolver.resolve(["http": ["rootProperty": "."]])
        XCTAssertEqual(resolution.config.http.rootProperty, ".")
        XCTAssertTrue(resolution.notes.contains { $0.kind == .adjusted })
        XCTAssertFalse(try ConfigResolver.resolve(["http": ["rootProperty": ".", "batch": false]]).notes.contains { $0.kind == .adjusted })
    }

    func testAllEnumValuesAccepted() throws {
        for a in Accuracy.allCases { XCTAssertEqual(try resolve(["accuracy": .string(a.rawValue)]).accuracy, a) }
        for m in HTTPMethod.allCases { XCTAssertEqual(try resolve(["http": ["method": .string(m.rawValue)]]).http.method, m) }
        for t in ActivityType.allCases { XCTAssertEqual(try resolve(["ios": ["activityType": .string(t.rawValue)]]).ios.activityType, t) }
        for l in LogLevel.allCases { XCTAssertEqual(try resolve(["logLevel": .string(l.rawValue)]).logLevel, l) }
        for p in NotificationPriority.allCases {
            XCTAssertEqual(try resolve(["notification": ["priority": .string(p.rawValue)]]).notification.priority, p)
        }
    }

    func testLogLevelThresholds() {
        XCTAssertTrue(LogLevel.info.allows(.error))
        XCTAssertTrue(LogLevel.info.allows(.info))
        XCTAssertFalse(LogLevel.info.allows(.debug))
        XCTAssertFalse(LogLevel.off.allows(.error))
        XCTAssertTrue(LogLevel.debug.allows(.debug))
        XCTAssertEqual(LogLevel.info.label, "INFO ")
    }
}

extension LongPingConfig {
    func with(_ change: (inout LongPingConfig) -> Void) -> LongPingConfig {
        var copy = self
        change(&copy)
        return copy
    }
}
