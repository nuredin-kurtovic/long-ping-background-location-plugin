# Long Ping — engineering contract

Internal. This is the single source of truth both native engines implement. When code and this file
disagree, one of them is a bug.

## Principles

1. **Native owns the job.** Taking fixes, deciding moving/parked, queueing, uploading, restarting after
   kills and reboots all happen in native code. JavaScript is a control surface (configure, start, stop,
   tokens, events for UI). Nothing depends on JS running in the background.
2. **A clock, not a guess.** Fixes are taken on a fixed interval the integrator sets (1 s and up), one
   for moving and one for parked. Moving/parked comes from the fixes themselves (speed + displacement),
   never from an OS activity classifier.
3. **Never stop on our own.** Only `stop()` (or a server `long_ping.stop`) stops tracking. Auth failures,
   network failures and bad responses pause or retry uploads; they never stop location.
4. **Never prompt on our own.** `configure()` and `start()` never show a permission dialog.
   `requestPermission()` is the only call that does.
5. **No third-party dependencies** beyond Google Play Services Location + AndroidX WorkManager (Android) and
   Apple frameworks (iOS).
6. **Explain every silence.** Every state change, restart, upload result and rejected fix is written to the
   on-device log, readable through `getLog()`.

## Package layout

```
package.json              react-native-long-ping (TurboModule, codegen name LongPingSpec)
src/                      NativeLongPing.ts (codegen spec), index.ts (public API), types.ts
LongPing.podspec          pod "LongPing"
ios/LongPing.mm|.h        RN bridge (ObjC++), subclass of RCTEventEmitter, conforms to NativeLongPingSpec
ios/Engine/*.swift        engine (CoreLocation, UIKit, sqlite3, Keychain, URLSession)
ios/Core/*.swift          pure Foundation logic (no UIKit/CoreLocation) — also a SwiftPM target
ios/Package.swift         SwiftPM package for Core + CoreTests (`swift test` on macOS)
android/                  com.longping — LongPingModule (RN bridge) + engine + core
android/src/main/java/com/longping/core/   pure Kotlin logic, no android.* imports
tools/android-core-tests/ standalone JVM Gradle project compiling core/ + its tests
```

Native module name: `LongPing`. Android package: `com.longping`. Codegen spec class: `NativeLongPingSpec`
(Android `com.longping.NativeLongPingSpec`, iOS protocol `NativeLongPingSpec` from `<LongPingSpec/LongPingSpec.h>`).
Requires React Native >= 0.76 with the New Architecture. iOS >= 15.1, Android minSdk 24, targetSdk 36.

## Bridge methods (exact; see src/NativeLongPing.ts)

All return promises. `Object` arrives as ReadableMap / NSDictionary. Errors reject with a `code` from the
Error codes table.

| method | does |
|---|---|
| `configure(config)` | Replace the app's config with defaults + `config`, validate, persist, apply live. The server's overrides stay on top (see Remote config). Idempotent; safe every launch. Does not start or stop. Resolves State. |
| `setConfig(partial)` | Deep-merge into the app's config (objects merge, arrays/scalars replace), validate, persist, apply. The server's overrides stay on top. Resolves State. |
| `start()` | Check permission; persist `enabled=true`; begin tracking; take an immediate `motionchange` fix (state = moving). Resolves State. Rejects `PERMISSION_DENIED`, `LOCATION_SERVICES_OFF` (still persists nothing in that case). |
| `stop()` | Persist `enabled=false`; stop updates/service/regions. Queue is kept and still uploads. Resolves State. |
| `getState()` | Resolves State. |
| `setAuthorization(auth)` | Store `{accessToken, refreshToken?, refreshUrl?, refreshPayload?, refreshHeaders?}` in secure storage; clear `authorizationRequired`; trigger an upload. |
| `clearAuthorization()` | Delete stored auth. |
| `getCurrentPosition(opts)` | One fix. opts: `timeoutSec` (30), `maximumAgeSec` (0), `accuracy` (config accuracy), `persist` (false), `extras` ({}). With `persist` the fix is recorded with event `current` (and uploaded). Works while stopped (needs permission). On timeout resolves the best fix seen in the window if any, else the last known fix if younger than 10 min, else rejects `TIMEOUT`. |
| `changePace(isMoving)` | Force moving/parked now; records a `motionchange` fix (which one: see Stop detection). Rejects `NOT_ENABLED` when stopped. |
| `sync()` | Upload the queue now (ignores uploadIntervalSec and backoff). Resolves number of records uploaded. |
| `getQueueCount()` | Records waiting. |
| `clearQueue()` | Delete all queued records. |
| `getProviderState()` | ProviderState. |
| `requestPermission(level)` | `'whenInUse'` or `'always'`. Shows the OS flow; resolves AuthorizationStatus (number). Android `'always'`: requests foreground first, then background (Android 11+ opens the system page). iOS `'always'`: whenInUse first, then `requestAlwaysAuthorization`. Never shows custom UI — rationale screens are the app's job. |
| `isIgnoringBatteryOptimizations()` | Android: PowerManager answer. iOS: true. |
| `requestIgnoreBatteryOptimizations()` | Android: `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` if the app declares `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, else `ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS`. Resolves true if a screen opened. iOS: false. |
| `openPowerManagerSettings()` | Android: first OEM power/auto-start screen that resolves (Samsung, Xiaomi, Huawei, Oppo/Realme, Vivo, OnePlus, Asus, Letv, Meizu), else app details. Resolves true if a screen opened. iOS: false. |
| `openAppSettings()` / `openLocationSettings()` | Open those screens. iOS: both open the app's Settings page. |
| `getLog(opts)` | opts `sinceMs` (24 h ago), `limit` (1000), `order` ('asc'). Resolves text, one entry per line: `2026-10-26T12:00:00.123Z INFO  [tag] message`. |
| `clearLog()` | Delete the log. |
| `addListener(name)` / `removeListeners(count)` | Event emitter plumbing. |

Native must also expose events (names exact): `location`, `motionchange`, `http`, `providerchange`,
`authorization`, `enabledchange`, `configchange`, `error`. Payloads in the Events section. Events are only
emitted while a JS listener exists; nothing is buffered for JS.

## Config (keys exact; defaults in brackets)

```
movingIntervalSec     number        [30]    clamp 1..86400
parkedIntervalSec     number        [180]   clamp 1..86400
accuracy              'high'|'balanced'|'low'  ['high']
minAccuracyM          number        [100]   0 = accept any accuracy
stopTimeoutSec        number        [300]   clamp 30..86400
stopRadiusM           number        [75]    clamp 10..10000
movingSpeedMps        number        [3]     clamp 0.5..100
disableStopDetection  boolean       [false] true = always moving once started
lowBattery            {belowPct: number, intervalSec: number} | null  [null]
http: {
  url                 string|null   [null]  null/'' = record only, never upload
  method              'POST'|'PUT'  ['POST']
  headers             {string:string} [{}]
  batch               boolean       [true]
  maxBatchSize        number        [100]   clamp 1..1000
  uploadIntervalSec   number        [0]     0 = upload as soon as a fix is recorded
  rootProperty        string|null   [null]  null → 'location' (single) / 'locations' (batch); '.' = record at body root (single only)
  locationTemplate    string|null   [null]
  params              object        [{}]    merged into the body root
  extras              object        [{}]    added to every record as "extras"
  timeoutSec          number        [30]    clamp 5..120
}
persistence: { maxRecords number [10000] clamp 1..1000000, maxDays number [7] clamp 1..365 }
startOnBoot           boolean       [true]
stopOnTerminate       boolean       [false]
remoteConfig          boolean       [true]  apply the server's overrides (see Remote config); only the app sets it
notification (Android): { title ['Location tracking'], text ['Sharing your location'], channelName ['Location tracking'], smallIcon [null → app icon; a drawable/mipmap resource name], priority ['low'|'default'|'high', 'low'] }
ios: { showsBackgroundLocationIndicator [false], activityType ['automotive'|'otherNavigation'|'fitness'|'other', 'automotive'] }
logLevel              'off'|'error'|'warn'|'info'|'debug'  ['info']
logMaxDays            number        [3]     clamp 1..30
debug                 boolean       [false] Android: notification text shows last fix age + queue size
```

Unknown keys are ignored (logged at debug). A value of the wrong type rejects `INVALID_CONFIG` with the key
in the message. `locationTemplate` is validated by rendering a sample record and JSON-parsing the result;
failure rejects `INVALID_CONFIG`. Config is persisted as JSON (Android SharedPreferences `longping`,
key `config`; iOS UserDefaults suite `com.longping`, key `config`). That is the app's layer; the server's overrides
are stored apart (Android key `remote_overrides`, iOS key `remoteOverrides`). Auth secrets are never part of config.

## Remote config (server overrides)

The engine keeps two layers:

- **App config**: the result of `configure()` / `setConfig()`.
- **Server overrides**: every `long_ping.config` received, deep-merged into one object (the `setConfig` rules).

**Effective config** = the overrides deep-merged onto the app config, validated together. It is what the engine
runs and what `State.config` and `configchange` report.

- `configure()` and `setConfig()` change only the app config and never clear the overrides: a key the server set
  keeps the server's value until a reset. `setConfig` merges into the app config, not into the effective config.
- A `long_ping.config` that does not validate on top of the current config is rejected whole (logged); the stored
  overrides stay as they were.
- When a new app config makes the stored overrides invalid (e.g. an override of `lowBattery.belowPct` after the app
  dropped `lowBattery`), the app's call still succeeds: the overrides are cleared and the reason is logged as an
  error. The app's own invalid input still rejects `INVALID_CONFIG`. Same at launch for stored overrides.
- `{"long_ping": {"reset": true}}` clears all overrides. With `config` in the same reply, the reset runs first. A
  reset is honoured even while `remoteConfig` is false.
- `remoteConfig` is the app's switch. While it is false the overrides stay stored but are not applied, and a
  `long_ping.config` that arrives is ignored (not stored). Turning it back on applies the stored overrides again.
  A `remoteConfig` key from the server is dropped (logged at warn).
- `configchange` is emitted, with the effective config, when a server reply changed the effective config. A reply
  that changes nothing (the same config again) emits nothing and writes nothing.

## Effective interval

```
base = isMoving ? movingIntervalSec : parkedIntervalSec
if lowBattery != null && !charging && batteryPct < lowBattery.belowPct: base = max(base, lowBattery.intervalSec)
```

Recomputed on every fix, on motion change, on config change and on battery change. When it changes, the
OS location request is re-issued (Android) / the sampling schedule is updated (iOS).

## Recording rule

A fix from the OS is **recorded** (stored, emitted as `location`, queued for upload) when:

- its horizontal accuracy <= `minAccuracyM` (or `minAccuracyM` == 0), and
- `fix.time - lastRecordedTime >= effectiveInterval - tolerance`, tolerance = `min(0.5 s, 10% of interval)`.

Overdue rule: if `now - lastRecordedTime > effectiveInterval + 30 s` and only inaccurate fixes arrived, record
the most accurate fix seen since the last record (accuracy filter waived, logged).

Motion changes always record immediately (event `motionchange`), regardless of interval.

Android: the fused provider delivers on its own clock, about once per interval and often a little early (or
early by a lot when another request on the device wakes it). A fix skipped as too soon schedules one fresh
fix (`getCurrentLocation`) for the moment the interval is due (at least 1 s later); any record cancels it. Without
this a skip leaves the next fix a whole interval away. iOS needs no equivalent: it delivers every second
around the due time.

`event` values: `interval` (normal), `motionchange`, `current` (getCurrentPosition with persist).

## Stop detection (pure core; identical on both platforms)

Inputs per fix: lat, lon, horizontal accuracy (m), speed (m/s, <0 unknown), time (ms). Only fixes with
accuracy <= max(minAccuracyM, stopRadiusM) are evaluated (if minAccuracyM is 0, use stopRadiusM).

Moving state keeps `anchor` (a fix):
- if `anchor == null` → anchor = fix.
- else if `distance(anchor, fix) > stopRadiusM` or `speed >= movingSpeedMps` → anchor = fix.
- else if `fix.time - anchor.time >= stopTimeoutSec * 1000` → **park**: state = parked, parkedAt = fix.

Parked state:
- if `speed >= movingSpeedMps` and `accuracy <= 50` → **move**.
- else if `distance(parkedAt, fix) > stopRadiusM` and `accuracy <= stopRadiusM` → **move**.
- On move: state = moving, anchor = fix.

`disableStopDetection` = never park. Distance = haversine, earth radius 6371008.8 m.

`changePace(true)` → moving, anchor = the point; `changePace(false)` → parked at the point. The point is the last
fix only if it is fresh (`now - fix.time <= 10 s`) and accurate (`minAccuracyM`); it is then recorded at once as
the `motionchange`. Otherwise the state is forced with no point, and the next fix becomes the point and is recorded
as the `motionchange` (with the accuracy wait every requested motion change has). A point that is not recorded at
once would judge the next fix and could undo the forced state before its `motionchange` exists.

iOS extra: on park, monitor a circular region (center parkedAt, radius `max(100, stopRadiusM * 2)`,
exit only); exit → move immediately. Remove the region on move/stop.

## Location record

Same object everywhere: emitted to JS, stored, and uploaded (default format). JSON:

```json
{
  "uuid": "6f1c2a1e-…",                 // v4, generated when recorded
  "timestamp": "2026-10-26T12:00:00.123Z", // fix time, UTC, ms precision
  "event": "interval",
  "is_moving": true,
  "coords": { "latitude": 43.85, "longitude": 18.41, "accuracy": 4.8,
              "speed": 12.3, "heading": 181.0, "altitude": 520.4 },
  "battery": { "level": 0.82, "is_charging": false },
  "mock": false,
  "extras": { }                          // only when non-empty (config.http.extras + per-call extras)
}
```

Unknown speed / heading = -1. Unknown altitude = null. Numbers are JSON numbers (no strings). Battery level 0..1
(-1 unknown).

## Upload

Queue = SQLite table, one row per record: `id` autoincrement, `uuid` unique, `recorded_at` ms, `json` text,
`attempts` int. Oldest first. Pruned after each insert: beyond `maxRecords` (oldest deleted) and older than
`maxDays`. Pruning is logged with counts.

Trigger an upload when: a record is inserted and (`uploadIntervalSec == 0` or that many seconds passed since
the last upload attempt); connectivity comes back; `sync()`; `setAuthorization()`; the 60 s watchdog tick
finds records and the next-attempt time has passed. One upload at a time (serial). Uploads continue while
tracking is stopped until the queue is empty.

Body (Content-Type `application/json`, Accept `application/json`):
- each record → the record JSON, or the rendered `locationTemplate` when set.
- batch (`batch: true`, up to `maxBatchSize` records): `{ ...params, [rootProperty ?? 'locations']: [r1, r2, …] }`.
- single (`batch: false`, one request per record): `rootProperty == '.'` → `{ ...params, ...r }`; otherwise
  `{ ...params, [rootProperty ?? 'location']: r }`.

Headers: config headers, then `Authorization: Bearer <accessToken>` when auth is stored (wins over a
configured Authorization header).

Template tokens (`{{name}}`, replaced with raw JSON values — strings are inserted WITHOUT quotes, the
template author writes the quotes): `uuid timestamp event is_moving latitude longitude accuracy speed heading
altitude battery_level battery_is_charging mock extras` (`extras` = JSON object text). Unknown token →
`INVALID_CONFIG` at configure time.

Response handling:
- **2xx** → delete the sent records; reset backoff; parse the body as JSON if possible; if it has a
  `long_ping` object: `reset: true` clears the server overrides, then `config` (partial Config) merges into them
  (see Remote config); `stop: true` stops tracking (emits `enabledchange`).
- **401 / 403** → if `refreshUrl` is stored: POST `refreshPayload` (default `{"refresh_token":"{{refreshToken}}"}`,
  `{{refreshToken}}` replaced) with `refreshHeaders`; read `access_token`|`accessToken` and optional
  `refresh_token`|`refreshToken` from the JSON reply; store; retry the batch once. Otherwise (no refresh URL,
  or refresh failed): `authorizationRequired = true`, emit `authorization` `{status, error}`, keep records,
  pause uploads until `setAuthorization()` or 15 min pass. Location keeps running. `error` is the same text on
  both platforms: `HTTP <status>` (no refresh possible), `token refresh failed: HTTP <status>` or
  `token refresh failed: <network error>`, `rejected after token refresh (HTTP <status>)`.
- **413** → retry immediately with half the batch (min 1).
- **408, 429, 5xx, network error, timeout** → keep records; backoff `min(900, 10 * 2^n)` s with ±20 % jitter;
  `Retry-After` (seconds) wins when present.
- **other 4xx** → `attempts += 1` on the sent records; delete records with attempts >= 3 (logged as dropped);
  normal pace continues.

Every attempt emits `http` `{ status (0 = network error), ok, count, responseText (first 2 KB) }` and logs a line.
Hold a partial wake lock (Android, 60 s timeout) / background task (iOS) for the duration of an upload.

## Lifecycle and recovery

Persisted engine state: `enabled`, `isMoving`, `anchor`, `parkedAt`, `lastRecordedTime`, `lastFixTime`.

Recording clock at engine start (process launch): `lastRecordedTime = min(now, max(persisted lastRecordedTime,
newest queued record's recorded_at, persisted lastLocationAt))`. State is persisted at most every 15 s (iOS) /
30 s (Android), so without the seed the first fix after a crash or kill could be recorded too early. The cap at
`now` keeps a clock that was set back from holding every new fix.

Watchdog (both, every 60 s while enabled): if `now - lastFixTime > max(2 × effectiveInterval, interval + 60 s)`,
log it and restart location updates. Also runs upload triggers and log pruning.

**Android**
- `LongPingService`: foreground service, `foregroundServiceType="location"`, `START_STICKY`, notification from
  config. Owns the FusedLocationProviderClient request:
  `LocationRequest.Builder(priority, intervalMs).setMinUpdateIntervalMillis(intervalMs).setMaxUpdateDelayMillis(0)
  .setWaitForAccurateLocation(false)`; priority high→HIGH_ACCURACY, balanced→BALANCED_POWER_ACCURACY,
  low→LOW_POWER. Re-issued when the effective interval or accuracy changes.
- Engine singleton survives without React (`LongPingEngine.get(context)`); the RN module only forwards.
- `LongPingBootReceiver`: BOOT_COMPLETED, MY_PACKAGE_REPLACED → if enabled && startOnBoot → start service.
- WorkManager unique periodic work (15 min): if enabled and the service is not running → start it. Starting a
  foreground service from the background can throw (`ForegroundServiceStartNotAllowedException`, Android 12+);
  catch, log, retry next period. Never crash the host app.
- Network: ConnectivityManager.NetworkCallback → upload trigger.
- Battery: ACTION_BATTERY_CHANGED sticky intent; changes re-evaluate the effective interval.
- Mock: `Location.isMock` (31+) / `isFromMockProvider`.
- Library manifest declares: ACCESS_FINE_LOCATION, ACCESS_COARSE_LOCATION, ACCESS_BACKGROUND_LOCATION,
  FOREGROUND_SERVICE, FOREGROUND_SERVICE_LOCATION, RECEIVE_BOOT_COMPLETED, WAKE_LOCK, INTERNET,
  ACCESS_NETWORK_STATE; the service and receiver. NOT REQUEST_IGNORE_BATTERY_OPTIMIZATIONS (Play policy —
  the app opts in).
- Auth secrets: AES-GCM with a non-exportable AndroidKeyStore key (alias `longping_auth`), ciphertext in
  SharedPreferences `longping`.
- AuthorizationStatus on Android: fine|coarse + background → ALWAYS; fine|coarse → WHEN_IN_USE; none →
  DENIED if we have asked before (flag in prefs) and `shouldShowRequestPermissionRationale` is false, else
  NOT_DETERMINED.

**iOS**
- CLLocationManager on the main thread. `allowsBackgroundLocationUpdates = true` ONLY if Info.plist
  `UIBackgroundModes` contains `location` (otherwise CoreLocation throws — log an error and continue
  foreground-only). `pausesLocationUpdatesAutomatically = false`, `distanceFilter = kCLDistanceFilterNone`,
  activityType from config, `showsBackgroundLocationIndicator` from config.
- Standard updates run the whole time tracking is enabled; that is what keeps the app alive in the
  background. Low-power mode between fixes when effectiveInterval >= 60 s: `desiredAccuracy =
  kCLLocationAccuracyThreeKilometers`; 15 s before the next fix is due switch to the configured accuracy
  (high → Best, balanced → HundredMeters, low → Kilometer), record per the Recording rule, then drop back.
  Below 60 s the configured accuracy stays on.
- Significant-change monitoring on while enabled; region on park (see Stop detection). Both relaunch a
  terminated app.
- Resume without JS: `+load` in LongPing.mm registers for `UIApplicationDidFinishLaunchingNotification` and calls
  `LongPingEngine.shared.resumeIfEnabled()`; the engine restarts updates if `enabled` and authorized.
- `UIApplicationWillTerminateNotification`: if `stopOnTerminate` → stop; else make sure significant-change +
  region monitoring are on; log.
- Network: NWPathMonitor → upload trigger. Uploads on a serial queue with URLSession, wrapped in
  `beginBackgroundTask`.
- Battery: `UIDevice.isBatteryMonitoringEnabled = true`, level/state notifications.
- Mock: `CLLocation.sourceInformation?.isSimulatedBySoftware` (iOS 15+).
- Storage: sqlite3 at Application Support/LongPing/longping.sqlite (excluded from backup). Auth secrets in
  Keychain (`kSecClassGenericPassword`, service `com.longping.auth`, `kSecAttrAccessibleAfterFirstUnlock`).
- AuthorizationStatus maps CLAuthorizationStatus directly (values below match Apple's order except 3/4).

## Types

AuthorizationStatus: `0 NOT_DETERMINED, 1 RESTRICTED, 2 DENIED, 3 ALWAYS, 4 WHEN_IN_USE`.

State (`config` is the effective config: app config + server overrides):
```
{ enabled, isMoving, lastLocation: Location|null, lastLocationAt: ms|null, queueCount,
  authorizationRequired, config }
```

ProviderState:
```
{ enabled, gps, network, status: AuthorizationStatus, accuracyAuthorization: 'full'|'reduced',
  powerSaveMode, ignoringBatteryOptimizations }
```

## Events

| name | payload |
|---|---|
| `location` | Location |
| `motionchange` | `{ isMoving, location }` |
| `http` | `{ status, ok, count, responseText }` |
| `providerchange` | ProviderState |
| `authorization` | `{ status, error }` (upload auth failed and could not refresh) |
| `enabledchange` | `{ enabled }` |
| `configchange` | effective Config (after a server reply's `config` / `reset` changed it) |
| `error` | `{ code, message }` (location errors, start failures in the background) |

## Error codes

`INVALID_CONFIG, PERMISSION_DENIED, LOCATION_SERVICES_OFF, NOT_ENABLED, TIMEOUT,
NO_ACTIVITY (Android, no foreground activity for a prompt), INTERNAL`.

## License

MIT. The engines do no license checks of any kind. A `licenseKey` left in an older config is ignored as an
unknown key (logged at debug).

## Clarifications (v0.1, both platforms)

Decisions taken while building the engines; they extend the sections above.

- `start()` when already enabled only makes sure tracking runs: no forced moving state, no extra motionchange.
  Calling it on every launch is safe.
- Config: `null` on a non-nullable key means its default; `''` on a nullable string means `null`; `http.url` must
  be an absolute http(s) URL; `lowBattery` needs both fields (belowPct 0..100, intervalSec 1..86400);
  `uploadIntervalSec` 0..86400; negative `minAccuracyM` is `INVALID_CONFIG`.
- `rootProperty: '.'` with `batch: true` is accepted and the batch goes under `locations`, so a remote config that
  flips batching on is never refused.
- Uploads: an "other 4xx" ends the current run (records retry on the next trigger, dropped at 3 attempts);
  `sync()` and `setAuthorization()` bypass both backoff and the 15-minute auth pause; connectivity returning only
  skips backoff when the last failure was a network error.
- Motion changes from `start()` / `changePace()` / region exit wait up to 30 s for an accurate fix, then record
  the best one seen. `current` records never reset the interval clock while the engine runs (the seed at engine
  start takes the newest stored record of any kind).
- `getLog` returns the newest `limit` entries since `sinceMs`, in the requested order.
- Unknown horizontal accuracy is `-1`.
- Android: `POST_NOTIFICATIONS` is the app's to request; without it the tracking notification is hidden on 13+.
  Devices without Google Play Services get no location (fused provider only in v0.1).
- iOS: the stored auth is wiped on the first launch after a (re)install, because the Keychain outlives uninstall.

Known differences, acceptable for v0.1: iOS also accepts an HTTP-date `Retry-After`; `getCurrentPosition` resolves
early at 20/100/1000 m (high/balanced/low) on iOS and at `minAccuracyM` on Android; engine state is persisted at
most every 15 s (iOS) / 30 s (Android) (the recording clock is seeded at engine start; see Lifecycle and recovery).

## Changes in v0.1.1 (both platforms)

- Server overrides are their own layer and survive `configure()` until `long_ping.reset` (see Remote config).
- The recording clock is seeded at engine start (see Lifecycle and recovery).
- `changePace()` uses the last fix as its point only when it records it at once (see Stop detection). iOS used a
  fresh but inaccurate fix as the point; Android was fixed in 3c3cbf2.
- The `authorization` event's `error` text is the same on both platforms (see Upload → Response handling).
