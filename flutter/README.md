# Long Ping for Flutter

Background location for Flutter that reports on a clock you set: every 5 seconds, every minute, every 10 minutes,
whatever your product needs. Separate intervals for moving and parked. A native upload queue that survives dead
zones, app kills and reboots. Built for fleets, deliveries and field teams, where "the phone went quiet for three
hours" is not acceptable.

- **Any interval, from 1 second.** Fixes come from a fixed clock, not from a motion classifier that can get stuck
  in the wrong state on some phones.
- **Native end to end.** Taking fixes, deciding moving/parked, storing and uploading all run in Kotlin and Swift.
  Dart can be paused, killed or never started; tracking carries on.
- **Uploads that don't give up or give in.** SQLite queue, batching, exponential backoff, token refresh. A 401
  pauses uploads until you hand over a new token; it never stops tracking.
- **Your server, your format.** Default JSON, or your own template per record. Change intervals from your server
  by adding a field to the upload response; no app release needed.
- **Recovers on its own.** Android restarts after reboots, app updates and service kills. iOS relaunches after
  termination on significant movement or leaving the parked area.
- **Explains its silences.** An on-device log of every state change, restart and upload, readable from Dart.

The same native engine as [react-native-long-ping](https://www.npmjs.com/package/react-native-long-ping). Free and
open source (MIT). No license key, no paid tier.

**Docs and guides: [longping.dev](https://longping.dev/docs/getting-started/flutter/)**

Requires Flutter 3.24+, iOS 15.1+, Android 7.0+ (API 24).

## Install

```sh
flutter pub add long_ping
```

### iOS

`ios/Podfile`:

```ruby
platform :ios, '15.1'
```

`ios/Runner/Info.plist`:

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Your location is shared with dispatch while you are on duty.</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Your location is shared with dispatch while you are on duty, including when the app is closed.</string>
<key>UIBackgroundModes</key>
<array>
  <string>location</string>
</array>
```

### Android

Nothing to add: the plugin's manifest brings the location, foreground-service and boot permissions. On Android
13+ declare `<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />` in your app's manifest
(the plugin doesn't) and ask for it, so the tracking notification is visible.

**Google Play.** The plugin adds `ACCESS_BACKGROUND_LOCATION` and a foreground service of type `location` to your
app, so Play will ask for the background-location and foreground-service declarations in the Play Console. If your
app only tracks while it is open, remove the background permission in your app's `AndroidManifest.xml`:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
          xmlns:tools="http://schemas.android.com/tools">
  <uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" tools:node="remove" />
</manifest>
```

## Quick start

```dart
import 'package:long_ping/long_ping.dart';

await LongPing.configure(const Config(
  movingIntervalSec: 30,
  parkedIntervalSec: 180,
  http: HttpConfig(
    url: 'https://api.example.com/locations',
    batch: true,
    uploadIntervalSec: 60,
  ),
  notification: NotificationConfig(title: 'On duty', text: 'Sharing your location with dispatch'),
));

await LongPing.setAuthorization(Authorization(accessToken: token));

// Your own rationale screen first, then:
await LongPing.requestPermission(PermissionLevel.always);
await LongPing.start();

final subscription = LongPing.onLocation.listen((location) => print(location.coords));
```

`configure()` is safe to call on every launch: it never starts, stops or shows a prompt. If tracking was running
when the app was killed, it is already running again by the time your Dart code runs.

Keep `onLocation` listeners light: use them for UI only. Dart may be paused or not running at all while the app is
in the background, and the native uploader already sends every record to `http.url`.

Failures throw `LongPingException` with a `LongPingErrorCode` (`permissionDenied`, `locationServicesOff`,
`invalidConfig`, …).

## What your server receives

`POST` (or `PUT`) with `Content-Type: application/json`. Batch mode:

```json
{
  "locations": [
    {
      "uuid": "6f1c2a1e-8b9e-4c1a-9a43-0d6c1d1a7f10",
      "timestamp": "2026-10-26T12:00:00.123Z",
      "event": "interval",
      "is_moving": true,
      "coords": { "latitude": 43.85, "longitude": 18.41, "accuracy": 4.8, "speed": 12.3, "heading": 181, "altitude": 520.4 },
      "battery": { "level": 0.82, "is_charging": false },
      "mock": false
    }
  ]
}
```

Reply with any 2xx to accept the batch. Include `{"long_ping": {"config": {"movingIntervalSec": 5}}}` in a reply to
change the device's config right away, even in the background; `{"long_ping": {"stop": true}}` stops tracking.

## Events

`onLocation`, `onMotionChange`, `onHttp`, `onProviderChange`, `onAuthorization`, `onEnabledChange`,
`onConfigChange`, `onError`: broadcast streams; cancel the subscription when you're done.

## Example

[`example/`](https://github.com/nuredin-kurtovic/long-ping-background-location-plugin/tree/main/flutter/example)
is a working app with a button for every command. Its `integration_test/` runs against the real engine on a
simulator or emulator.

## License

MIT. See `LICENSE`.
