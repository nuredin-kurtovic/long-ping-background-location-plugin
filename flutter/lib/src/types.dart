// Public types. Keys and defaults mirror DESIGN.md and react-native-long-ping's types.ts; only the names
// that would clash in a Flutter app differ (State -> LongPingState, AuthorizationStatus ->
// LocationAuthorizationStatus).

import 'codec.dart';

enum Accuracy { high, balanced, low }

enum LogLevel { off, error, warn, info, debug }

/// What produced a fix: the tracking clock, a moving/parked switch, or [LongPing.getCurrentPosition].
enum LocationEvent { interval, motionchange, current }

enum HttpMethod {
  post('POST'),
  put('PUT');

  const HttpMethod(this.wire);

  final String wire;
}

enum NotificationPriority {
  low('low'),
  normal('default'),
  high('high');

  const NotificationPriority(this.wire);

  final String wire;
}

enum IosActivityType { automotive, otherNavigation, fitness, other }

/// What [LongPing.requestPermission] asks for.
enum PermissionLevel { whenInUse, always }

/// Location permission as the OS reports it. The numbers match react-native-long-ping's AuthorizationStatus.
enum LocationAuthorizationStatus {
  notDetermined(0),
  restricted(1),
  denied(2),
  always(3),
  whenInUse(4);

  const LocationAuthorizationStatus(this.value);

  final int value;

  static LocationAuthorizationStatus fromValue(Object? value) =>
      enumOrNull(values, asIntOrNull(value), (status) => status.value) ?? notDetermined;
}

enum AccuracyAuthorization { full, reduced }

enum LogOrder { asc, desc }

enum LongPingErrorCode {
  invalidConfig('INVALID_CONFIG'),
  permissionDenied('PERMISSION_DENIED'),
  locationServicesOff('LOCATION_SERVICES_OFF'),
  notEnabled('NOT_ENABLED'),
  timeout('TIMEOUT'),
  noActivity('NO_ACTIVITY'),
  internal('INTERNAL');

  const LongPingErrorCode(this.wire);

  final String wire;

  static LongPingErrorCode fromWire(Object? wire) => enumOrNull(values, wire, (code) => code.wire) ?? internal;
}

/// Thrown by every [LongPing] call that fails. [message] starts with the config key for [LongPingErrorCode.invalidConfig].
class LongPingException implements Exception {
  const LongPingException(this.code, this.message);

  final LongPingErrorCode code;
  final String message;

  @override
  String toString() => 'LongPingException(${code.wire}): $message';
}

// ---------------------------------------------------------------- config

/// Tracking config. Every field is optional: [LongPing.configure] fills the rest with defaults (in brackets),
/// [LongPing.setConfig] keeps their current values. As read back in [LongPingState.config], every field is set.
class Config {
  const Config({
    this.movingIntervalSec,
    this.parkedIntervalSec,
    this.accuracy,
    this.minAccuracyM,
    this.stopTimeoutSec,
    this.stopRadiusM,
    this.movingSpeedMps,
    this.disableStopDetection,
    this.lowBattery,
    this.http,
    this.persistence,
    this.startOnBoot,
    this.stopOnTerminate,
    this.remoteConfig,
    this.notification,
    this.ios,
    this.logLevel,
    this.logMaxDays,
    this.debug,
  });

  /// Seconds between fixes while moving. 1..86400 [30].
  final double? movingIntervalSec;

  /// Seconds between fixes while parked. 1..86400 [180].
  final double? parkedIntervalSec;

  /// [Accuracy.high].
  final Accuracy? accuracy;

  /// Fixes less accurate than this (meters) are not recorded. 0 = accept all [100].
  final double? minAccuracyM;

  /// Parked after staying within [stopRadiusM] for this long. 30..86400 [300].
  final double? stopTimeoutSec;

  /// 10..10000 [75].
  final double? stopRadiusM;

  /// Speed (m/s) that counts as moving. 0.5..100 [3].
  final double? movingSpeedMps;

  /// Never switch to parked [false].
  final bool? disableStopDetection;

  /// When not charging and below [LowBattery.belowPct], use at least [LowBattery.intervalSec] [off].
  /// [LowBattery.off] switches it off.
  final LowBattery? lowBattery;

  final HttpConfig? http;

  final PersistenceConfig? persistence;

  /// Android: restart after a reboot or app update. (iOS relaunches on movement whenever tracking is on.) [true]
  final bool? startOnBoot;

  /// Stop tracking when the app is swiped away [false].
  final bool? stopOnTerminate;

  /// Apply the server's overrides (`long_ping.config` in upload responses). They are kept on the device across
  /// [LongPing.configure] / [LongPing.setConfig] until `long_ping.reset`; false keeps them stored but unused.
  /// Only the app sets this [true].
  final bool? remoteConfig;

  /// Android foreground-service notification.
  final NotificationConfig? notification;

  final IosConfig? ios;

  /// [LogLevel.info].
  final LogLevel? logLevel;

  /// 1..30 [3].
  final int? logMaxDays;

  /// Android: the notification shows the last fix age and queue size [false].
  final bool? debug;

  Map<String, Object?> toMap() => {
        if (movingIntervalSec != null) 'movingIntervalSec': movingIntervalSec,
        if (parkedIntervalSec != null) 'parkedIntervalSec': parkedIntervalSec,
        if (accuracy != null) 'accuracy': accuracy!.name,
        if (minAccuracyM != null) 'minAccuracyM': minAccuracyM,
        if (stopTimeoutSec != null) 'stopTimeoutSec': stopTimeoutSec,
        if (stopRadiusM != null) 'stopRadiusM': stopRadiusM,
        if (movingSpeedMps != null) 'movingSpeedMps': movingSpeedMps,
        if (disableStopDetection != null) 'disableStopDetection': disableStopDetection,
        if (lowBattery != null) 'lowBattery': lowBattery!._toWire(),
        if (http != null) 'http': http!.toMap(),
        if (persistence != null) 'persistence': persistence!.toMap(),
        if (startOnBoot != null) 'startOnBoot': startOnBoot,
        if (stopOnTerminate != null) 'stopOnTerminate': stopOnTerminate,
        if (remoteConfig != null) 'remoteConfig': remoteConfig,
        if (notification != null) 'notification': notification!.toMap(),
        if (ios != null) 'ios': ios!.toMap(),
        if (logLevel != null) 'logLevel': logLevel!.name,
        if (logMaxDays != null) 'logMaxDays': logMaxDays,
        if (debug != null) 'debug': debug,
      };

  factory Config.fromMap(Map<String, Object?> map) {
    final lowBattery = asMapOrNull(map['lowBattery']);
    final http = asMapOrNull(map['http']);
    final persistence = asMapOrNull(map['persistence']);
    final notification = asMapOrNull(map['notification']);
    final ios = asMapOrNull(map['ios']);
    return Config(
      movingIntervalSec: asDoubleOrNull(map['movingIntervalSec']),
      parkedIntervalSec: asDoubleOrNull(map['parkedIntervalSec']),
      accuracy: enumOrNull(Accuracy.values, map['accuracy'], (v) => v.name),
      minAccuracyM: asDoubleOrNull(map['minAccuracyM']),
      stopTimeoutSec: asDoubleOrNull(map['stopTimeoutSec']),
      stopRadiusM: asDoubleOrNull(map['stopRadiusM']),
      movingSpeedMps: asDoubleOrNull(map['movingSpeedMps']),
      disableStopDetection: asBoolOrNull(map['disableStopDetection']),
      lowBattery: lowBattery == null ? null : LowBattery.fromMap(lowBattery),
      http: http == null ? null : HttpConfig.fromMap(http),
      persistence: persistence == null ? null : PersistenceConfig.fromMap(persistence),
      startOnBoot: asBoolOrNull(map['startOnBoot']),
      stopOnTerminate: asBoolOrNull(map['stopOnTerminate']),
      remoteConfig: asBoolOrNull(map['remoteConfig']),
      notification: notification == null ? null : NotificationConfig.fromMap(notification),
      ios: ios == null ? null : IosConfig.fromMap(ios),
      logLevel: enumOrNull(LogLevel.values, map['logLevel'], (v) => v.name),
      logMaxDays: asIntOrNull(map['logMaxDays']),
      debug: asBoolOrNull(map['debug']),
    );
  }

  @override
  String toString() => 'Config(${toMap()})';
}

class LowBattery {
  const LowBattery({required this.belowPct, required this.intervalSec}) : _off = false;

  const LowBattery._off()
      : belowPct = 0,
        intervalSec = 0,
        _off = true;

  /// Switches the low-battery rule off, e.g. `setConfig(Config(lowBattery: LowBattery.off))`.
  static const LowBattery off = LowBattery._off();

  /// Battery percentage (0..100) below which the rule applies.
  final int belowPct;

  /// The longest interval allowed while it applies, in seconds.
  final double intervalSec;

  final bool _off;

  Object? _toWire() => _off ? null : {'belowPct': belowPct, 'intervalSec': intervalSec};

  factory LowBattery.fromMap(Map<String, Object?> map) =>
      LowBattery(belowPct: asInt(map['belowPct']), intervalSec: asDouble(map['intervalSec']));
}

class HttpConfig {
  const HttpConfig({
    this.url,
    this.method,
    this.headers,
    this.batch,
    this.maxBatchSize,
    this.uploadIntervalSec,
    this.rootProperty,
    this.locationTemplate,
    this.params,
    this.extras,
    this.timeoutSec,
  });

  /// Upload endpoint. Unset or '' = record locally, never upload.
  final String? url;

  /// [HttpMethod.post].
  final HttpMethod? method;

  final Map<String, String>? headers;

  /// Send several records per request [true].
  final bool? batch;

  /// 1..1000 [100].
  final int? maxBatchSize;

  /// 0 = upload as soon as a fix is recorded (default). N = at most one upload every N seconds.
  final double? uploadIntervalSec;

  /// Where records go in the body ['location' (single) / 'locations' (batch)]. '.' puts a single record at the
  /// body root; '' restores the default.
  final String? rootProperty;

  /// JSON template for each record, e.g. `'{"lat":{{latitude}},"lng":{{longitude}},"at":"{{timestamp}}"}'`.
  /// Tokens are replaced with raw values; write quotes around string tokens yourself. '' = default record.
  final String? locationTemplate;

  /// Merged into the body root of every request.
  final Map<String, Object?>? params;

  /// Added to every record as "extras".
  final Map<String, Object?>? extras;

  /// 5..120 [30].
  final double? timeoutSec;

  Map<String, Object?> toMap() => {
        if (url != null) 'url': url,
        if (method != null) 'method': method!.wire,
        if (headers != null) 'headers': headers,
        if (batch != null) 'batch': batch,
        if (maxBatchSize != null) 'maxBatchSize': maxBatchSize,
        if (uploadIntervalSec != null) 'uploadIntervalSec': uploadIntervalSec,
        if (rootProperty != null) 'rootProperty': rootProperty,
        if (locationTemplate != null) 'locationTemplate': locationTemplate,
        if (params != null) 'params': params,
        if (extras != null) 'extras': extras,
        if (timeoutSec != null) 'timeoutSec': timeoutSec,
      };

  factory HttpConfig.fromMap(Map<String, Object?> map) => HttpConfig(
        url: asStringOrNull(map['url']),
        method: enumOrNull(HttpMethod.values, map['method'], (v) => v.wire),
        headers: asStringMapOrNull(map['headers']),
        batch: asBoolOrNull(map['batch']),
        maxBatchSize: asIntOrNull(map['maxBatchSize']),
        uploadIntervalSec: asDoubleOrNull(map['uploadIntervalSec']),
        rootProperty: asStringOrNull(map['rootProperty']),
        locationTemplate: asStringOrNull(map['locationTemplate']),
        params: asMapOrNull(map['params']),
        extras: asMapOrNull(map['extras']),
        timeoutSec: asDoubleOrNull(map['timeoutSec']),
      );
}

class PersistenceConfig {
  const PersistenceConfig({this.maxRecords, this.maxDays});

  /// 1..1000000 [10000].
  final int? maxRecords;

  /// 1..365 [7].
  final int? maxDays;

  Map<String, Object?> toMap() => {
        if (maxRecords != null) 'maxRecords': maxRecords,
        if (maxDays != null) 'maxDays': maxDays,
      };

  factory PersistenceConfig.fromMap(Map<String, Object?> map) =>
      PersistenceConfig(maxRecords: asIntOrNull(map['maxRecords']), maxDays: asIntOrNull(map['maxDays']));
}

class NotificationConfig {
  const NotificationConfig({this.title, this.text, this.channelName, this.smallIcon, this.priority});

  final String? title;
  final String? text;
  final String? channelName;

  /// Drawable or mipmap resource name. Default: the app icon.
  final String? smallIcon;

  /// [NotificationPriority.low].
  final NotificationPriority? priority;

  Map<String, Object?> toMap() => {
        if (title != null) 'title': title,
        if (text != null) 'text': text,
        if (channelName != null) 'channelName': channelName,
        if (smallIcon != null) 'smallIcon': smallIcon,
        if (priority != null) 'priority': priority!.wire,
      };

  factory NotificationConfig.fromMap(Map<String, Object?> map) => NotificationConfig(
        title: asStringOrNull(map['title']),
        text: asStringOrNull(map['text']),
        channelName: asStringOrNull(map['channelName']),
        smallIcon: asStringOrNull(map['smallIcon']),
        priority: enumOrNull(NotificationPriority.values, map['priority'], (v) => v.wire),
      );
}

class IosConfig {
  const IosConfig({this.showsBackgroundLocationIndicator, this.activityType});

  /// [false].
  final bool? showsBackgroundLocationIndicator;

  /// [IosActivityType.automotive].
  final IosActivityType? activityType;

  Map<String, Object?> toMap() => {
        if (showsBackgroundLocationIndicator != null)
          'showsBackgroundLocationIndicator': showsBackgroundLocationIndicator,
        if (activityType != null) 'activityType': activityType!.name,
      };

  factory IosConfig.fromMap(Map<String, Object?> map) => IosConfig(
        showsBackgroundLocationIndicator: asBoolOrNull(map['showsBackgroundLocationIndicator']),
        activityType: enumOrNull(IosActivityType.values, map['activityType'], (v) => v.name),
      );
}

/// Upload credentials, kept in secure storage (Keychain / encrypted preferences).
class Authorization {
  const Authorization({
    required this.accessToken,
    this.refreshToken,
    this.refreshUrl,
    this.refreshPayload,
    this.refreshHeaders,
  });

  final String accessToken;
  final String? refreshToken;

  /// POSTed with [refreshPayload] on a 401/403; the reply must carry access_token (and optionally refresh_token).
  final String? refreshUrl;

  /// Default `{"refresh_token": "{{refreshToken}}"}`.
  final Map<String, String>? refreshPayload;

  final Map<String, String>? refreshHeaders;

  Map<String, Object?> toMap() => {
        'accessToken': accessToken,
        if (refreshToken != null) 'refreshToken': refreshToken,
        if (refreshUrl != null) 'refreshUrl': refreshUrl,
        if (refreshPayload != null) 'refreshPayload': refreshPayload,
        if (refreshHeaders != null) 'refreshHeaders': refreshHeaders,
      };
}

// ---------------------------------------------------------------- results and events

class Coords {
  const Coords({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.speed,
    required this.heading,
    this.altitude,
  });

  final double latitude;
  final double longitude;

  /// Horizontal accuracy, meters.
  final double accuracy;

  /// m/s, -1 unknown.
  final double speed;

  /// Degrees, -1 unknown.
  final double heading;

  /// Meters, null unknown.
  final double? altitude;

  factory Coords.fromMap(Map<String, Object?> map) => Coords(
        latitude: asDouble(map['latitude']),
        longitude: asDouble(map['longitude']),
        accuracy: asDouble(map['accuracy'], -1),
        speed: asDouble(map['speed'], -1),
        heading: asDouble(map['heading'], -1),
        altitude: asDoubleOrNull(map['altitude']),
      );

  Map<String, Object?> toMap() => {
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracy,
        'speed': speed,
        'heading': heading,
        'altitude': altitude,
      };

  @override
  String toString() => 'Coords($latitude, $longitude ±${accuracy}m)';
}

class Battery {
  const Battery({required this.level, required this.isCharging});

  /// 0..1, -1 unknown.
  final double level;
  final bool isCharging;
}

/// One recorded fix, exactly as it is stored and uploaded.
class Location {
  const Location({
    required this.uuid,
    required this.timestamp,
    required this.event,
    required this.isMoving,
    required this.coords,
    required this.battery,
    required this.mock,
    this.extras,
  });

  /// Unique per fix, so a retried upload can be de-duplicated.
  final String uuid;

  /// UTC, millisecond precision.
  final DateTime timestamp;

  final LocationEvent event;
  final bool isMoving;
  final Coords coords;
  final Battery battery;

  /// The OS flagged the fix as coming from a mock location provider.
  final bool mock;

  final Map<String, Object?>? extras;

  factory Location.fromMap(Map<String, Object?> map) {
    final battery = asMap(map['battery']);
    return Location(
      uuid: asString(map['uuid']),
      timestamp:
          DateTime.tryParse(asString(map['timestamp']))?.toUtc() ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      event: enumOrNull(LocationEvent.values, map['event'], (v) => v.name) ?? LocationEvent.interval,
      isMoving: asBool(map['is_moving']),
      coords: Coords.fromMap(asMap(map['coords'])),
      battery: Battery(level: asDouble(battery['level'], -1), isCharging: asBool(battery['is_charging'])),
      mock: asBool(map['mock']),
      extras: asMapOrNull(map['extras']),
    );
  }

  /// The record in the default upload format.
  Map<String, Object?> toMap() => {
        'uuid': uuid,
        'timestamp': timestamp.toIso8601String(),
        'event': event.name,
        'is_moving': isMoving,
        'coords': coords.toMap(),
        'battery': {'level': battery.level, 'is_charging': battery.isCharging},
        'mock': mock,
        if (extras != null) 'extras': extras,
      };

  @override
  String toString() => 'Location(${timestamp.toIso8601String()}, ${event.name}, $coords)';
}

class LongPingState {
  const LongPingState({
    required this.enabled,
    required this.isMoving,
    required this.lastLocation,
    required this.lastLocationAt,
    required this.queueCount,
    required this.authorizationRequired,
    required this.config,
  });

  /// Tracking is on (it stays on across app kills and reboots until [LongPing.stop]).
  final bool enabled;

  final bool isMoving;
  final Location? lastLocation;

  /// When [lastLocation] was recorded.
  final DateTime? lastLocationAt;

  /// Records waiting to upload.
  final int queueCount;

  /// The server answered 401/403 and the token could not be refreshed: uploads wait for [LongPing.setAuthorization].
  final bool authorizationRequired;

  /// The config in effect: your app's config with the server's overrides on top.
  final Config config;

  factory LongPingState.fromMap(Map<String, Object?> map) {
    final lastLocation = asMapOrNull(map['lastLocation']);
    final lastLocationAt = asIntOrNull(map['lastLocationAt']);
    return LongPingState(
      enabled: asBool(map['enabled']),
      isMoving: asBool(map['isMoving']),
      lastLocation: lastLocation == null ? null : Location.fromMap(lastLocation),
      lastLocationAt: lastLocationAt == null ? null : DateTime.fromMillisecondsSinceEpoch(lastLocationAt, isUtc: true),
      queueCount: asInt(map['queueCount']),
      authorizationRequired: asBool(map['authorizationRequired']),
      config: Config.fromMap(asMap(map['config'])),
    );
  }

  @override
  String toString() => 'LongPingState(enabled: $enabled, isMoving: $isMoving, queueCount: $queueCount)';
}

class ProviderState {
  const ProviderState({
    required this.enabled,
    required this.gps,
    required this.network,
    required this.status,
    required this.accuracyAuthorization,
    required this.powerSaveMode,
    required this.ignoringBatteryOptimizations,
  });

  /// Location services switched on.
  final bool enabled;

  final bool gps;
  final bool network;
  final LocationAuthorizationStatus status;
  final AccuracyAuthorization accuracyAuthorization;
  final bool powerSaveMode;

  /// Android only; always true on iOS.
  final bool ignoringBatteryOptimizations;

  factory ProviderState.fromMap(Map<String, Object?> map) => ProviderState(
        enabled: asBool(map['enabled']),
        gps: asBool(map['gps']),
        network: asBool(map['network']),
        status: LocationAuthorizationStatus.fromValue(map['status']),
        accuracyAuthorization: enumOrNull(AccuracyAuthorization.values, map['accuracyAuthorization'], (v) => v.name) ??
            AccuracyAuthorization.full,
        powerSaveMode: asBool(map['powerSaveMode']),
        ignoringBatteryOptimizations: asBool(map['ignoringBatteryOptimizations'], true),
      );
}

class MotionChangeEvent {
  const MotionChangeEvent({required this.isMoving, required this.location});

  final bool isMoving;
  final Location location;

  factory MotionChangeEvent.fromMap(Map<String, Object?> map) =>
      MotionChangeEvent(isMoving: asBool(map['isMoving']), location: Location.fromMap(asMap(map['location'])));
}

/// One upload attempt.
class HttpEvent {
  const HttpEvent({required this.status, required this.ok, required this.count, required this.responseText});

  /// HTTP status; 0 = network error.
  final int status;

  final bool ok;

  /// Records in the request.
  final int count;

  final String responseText;

  factory HttpEvent.fromMap(Map<String, Object?> map) => HttpEvent(
        status: asInt(map['status']),
        ok: asBool(map['ok']),
        count: asInt(map['count']),
        responseText: asString(map['responseText']),
      );
}

/// Uploads were refused (401/403) and the token could not be refreshed: they wait for [LongPing.setAuthorization].
class AuthorizationEvent {
  const AuthorizationEvent({required this.status, this.error});

  /// HTTP status; 0 = network error.
  final int status;

  final String? error;

  factory AuthorizationEvent.fromMap(Map<String, Object?> map) =>
      AuthorizationEvent(status: asInt(map['status']), error: asStringOrNull(map['error']));
}

/// A location error, or a start that failed while the app was in the background.
class ErrorEvent {
  const ErrorEvent({required this.code, required this.message});

  final LongPingErrorCode code;
  final String message;

  factory ErrorEvent.fromMap(Map<String, Object?> map) =>
      ErrorEvent(code: LongPingErrorCode.fromWire(map['code']), message: asString(map['message']));
}
