/// Background location on a fixed clock: any interval from 1 second, a native upload queue, survives app kills
/// and reboots. The same native engine as react-native-long-ping. Docs: https://longping.dev
library;

import 'dart:async';

import 'package:flutter/services.dart';

import 'src/codec.dart';
import 'src/types.dart';

export 'src/types.dart';

/// Every call goes to the native engine, which keeps tracking and uploading whether or not Dart is running.
/// Failures throw [LongPingException].
abstract final class LongPing {
  static const MethodChannel _methods = MethodChannel('long_ping');
  static const EventChannel _eventChannel = EventChannel('long_ping/events');

  // One platform subscription shared by every stream: a second one would replace the first natively.
  static final Stream<Map<Object?, Object?>> _events = _eventChannel.receiveBroadcastStream().cast();

  /// Replace your app's config (defaults + [config]). Server overrides (`long_ping.config`) stay on top until
  /// `long_ping.reset`. Safe on every launch: never starts, stops or prompts.
  static Future<LongPingState> configure(Config config) async =>
      LongPingState.fromMap(asMap(await _invoke('configure', config.toMap())));

  /// Merge [config] into your app's config and apply it live. Server overrides stay on top.
  static Future<LongPingState> setConfig(Config config) async =>
      LongPingState.fromMap(asMap(await _invoke('setConfig', config.toMap())));

  /// Start tracking. Throws [LongPingErrorCode.permissionDenied] or [LongPingErrorCode.locationServicesOff];
  /// never prompts.
  static Future<LongPingState> start() async => LongPingState.fromMap(asMap(await _invoke('start')));

  /// Stop tracking. Queued records still upload.
  static Future<LongPingState> stop() async => LongPingState.fromMap(asMap(await _invoke('stop')));

  static Future<LongPingState> getState() async => LongPingState.fromMap(asMap(await _invoke('getState')));

  /// Store upload credentials (secure storage) and retry any held uploads.
  static Future<void> setAuthorization(Authorization authorization) =>
      _invoke('setAuthorization', authorization.toMap());

  static Future<void> clearAuthorization() => _invoke('clearAuthorization');

  /// One fix now. [maximumAgeSec] accepts a cached fix that young; [persist] records and uploads it
  /// (event `current`) with [extras] attached.
  static Future<Location> getCurrentPosition({
    double? timeoutSec,
    double? maximumAgeSec,
    Accuracy? accuracy,
    bool? persist,
    Map<String, Object?>? extras,
  }) async =>
      Location.fromMap(asMap(await _invoke('getCurrentPosition', {
        if (timeoutSec != null) 'timeoutSec': timeoutSec,
        if (maximumAgeSec != null) 'maximumAgeSec': maximumAgeSec,
        if (accuracy != null) 'accuracy': accuracy.name,
        if (persist != null) 'persist': persist,
        if (extras != null) 'extras': extras,
      })));

  /// Force moving (true) or parked (false) now.
  static Future<LongPingState> changePace(bool isMoving) async =>
      LongPingState.fromMap(asMap(await _invoke('changePace', isMoving)));

  /// Upload the queue now. Returns the number of records uploaded.
  static Future<int> sync() async => asInt(await _invoke('sync'));

  static Future<int> getQueueCount() async => asInt(await _invoke('getQueueCount'));

  static Future<void> clearQueue() => _invoke('clearQueue');

  static Future<ProviderState> getProviderState() async =>
      ProviderState.fromMap(asMap(await _invoke('getProviderState')));

  /// The only call that shows a permission dialog. Show your own rationale first.
  static Future<LocationAuthorizationStatus> requestPermission(PermissionLevel level) async =>
      LocationAuthorizationStatus.fromValue(await _invoke('requestPermission', level.name));

  static const LongPingDeviceSettings deviceSettings = LongPingDeviceSettings._();

  static const LongPingLogger logger = LongPingLogger._();

  /// Every recorded fix. Keep listeners light (UI only): Dart may be paused or not running in the background,
  /// and the native uploader already sends every record to `http.url`.
  static Stream<Location> get onLocation => _on('location', (payload) => Location.fromMap(asMap(payload)));

  static Stream<MotionChangeEvent> get onMotionChange =>
      _on('motionchange', (payload) => MotionChangeEvent.fromMap(asMap(payload)));

  static Stream<HttpEvent> get onHttp => _on('http', (payload) => HttpEvent.fromMap(asMap(payload)));

  static Stream<ProviderState> get onProviderChange =>
      _on('providerchange', (payload) => ProviderState.fromMap(asMap(payload)));

  static Stream<AuthorizationEvent> get onAuthorization =>
      _on('authorization', (payload) => AuthorizationEvent.fromMap(asMap(payload)));

  /// Tracking switched on or off (including by your server's `long_ping.stop`).
  static Stream<bool> get onEnabledChange => _on('enabledchange', (payload) => asBool(asMap(payload)['enabled']));

  /// The config in effect changed because of a server reply (`long_ping.config` / `long_ping.reset`).
  static Stream<Config> get onConfigChange => _on('configchange', (payload) => Config.fromMap(asMap(payload)));

  static Stream<ErrorEvent> get onError => _on('error', (payload) => ErrorEvent.fromMap(asMap(payload)));

  static Stream<T> _on<T>(String name, T Function(Object? payload) parse) =>
      _events.where((event) => event['event'] == name).map((event) => parse(event['payload']));
}

/// Device settings screens. On iOS only the app's own Settings page exists; the Android-only calls answer
/// false (and [isIgnoringBatteryOptimizations] true).
final class LongPingDeviceSettings {
  const LongPingDeviceSettings._();

  Future<bool> isIgnoringBatteryOptimizations() async => asBool(await _invoke('isIgnoringBatteryOptimizations'));

  /// The direct "allow" dialog needs `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` declared in your manifest; without
  /// it, the battery optimization list opens instead.
  Future<bool> requestIgnoreBatteryOptimizations() async => asBool(await _invoke('requestIgnoreBatteryOptimizations'));

  /// The OEM battery manager (Samsung, Xiaomi, Huawei and others) where one exists, else the app's settings
  /// page; see dontkillmyapp.com.
  Future<bool> openPowerManagerSettings() async => asBool(await _invoke('openPowerManagerSettings'));

  Future<bool> openAppSettings() async => asBool(await _invoke('openAppSettings'));

  Future<bool> openLocationSettings() async => asBool(await _invoke('openLocationSettings'));
}

/// The on-device log of every state change, restart and upload.
final class LongPingLogger {
  const LongPingLogger._();

  /// Log lines as text. [since] defaults to 24 hours ago, [limit] to 1000.
  Future<String> getLog({DateTime? since, int? limit, LogOrder? order}) async => asString(await _invoke('getLog', {
        if (since != null) 'sinceMs': since.millisecondsSinceEpoch,
        if (limit != null) 'limit': limit,
        if (order != null) 'order': order.name,
      }));

  Future<void> clear() => _invoke('clearLog');
}

Future<Object?> _invoke(String method, [Object? arguments]) async {
  try {
    return await LongPing._methods.invokeMethod<Object?>(method, arguments);
  } on PlatformException catch (e) {
    throw LongPingException(LongPingErrorCode.fromWire(e.code), e.message ?? e.code);
  }
}
