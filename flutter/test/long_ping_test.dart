import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:long_ping/long_ping.dart';

// Payloads as the iOS engine sends them: every number a double.
final Map<String, Object?> _location = {
  'uuid': '6f1c2a1e-8b9e-4c1a-9a43-0d6c1d1a7f10',
  'timestamp': '2026-10-26T12:00:00.123Z',
  'event': 'interval',
  'is_moving': true,
  'coords': {'latitude': 43.85, 'longitude': 18.41, 'accuracy': 4.8, 'speed': 12.3, 'heading': 181.0, 'altitude': null},
  'battery': {'level': 0.82, 'is_charging': false},
  'mock': false,
};

final Map<String, Object?> _state = {
  'enabled': true,
  'isMoving': false,
  'lastLocation': _location,
  'lastLocationAt': 1793016000123.0,
  'queueCount': 3.0,
  'authorizationRequired': false,
  'config': {
    'movingIntervalSec': 30.0,
    'parkedIntervalSec': 180.0,
    'accuracy': 'high',
    'lowBattery': null,
    'http': {'url': null, 'method': 'POST', 'headers': {}, 'batch': true, 'maxBatchSize': 100.0},
    'persistence': {'maxRecords': 10000.0, 'maxDays': 7.0},
    'notification': {'priority': 'default'},
    'ios': {'activityType': 'otherNavigation'},
    'logLevel': 'info',
    'logMaxDays': 3.0,
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('long_ping');
  const events = EventChannel('long_ping/events');

  late List<MethodCall> calls;
  late Object? Function(MethodCall call) reply;

  setUp(() {
    calls = [];
    reply = (_) => null;
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return reply(call);
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(methods, null));

  group('config', () {
    test('sends only the keys that are set, with wire values', () async {
      reply = (_) => _state;
      await LongPing.configure(const Config(
        movingIntervalSec: 5,
        accuracy: Accuracy.balanced,
        http: HttpConfig(url: 'https://api.example.com/locations', method: HttpMethod.put, uploadIntervalSec: 60),
        notification: NotificationConfig(title: 'On duty', priority: NotificationPriority.normal),
        ios: IosConfig(activityType: IosActivityType.otherNavigation),
        logLevel: LogLevel.debug,
      ));
      expect(calls.single.method, 'configure');
      expect(calls.single.arguments, {
        'movingIntervalSec': 5.0,
        'accuracy': 'balanced',
        'http': {'url': 'https://api.example.com/locations', 'method': 'PUT', 'uploadIntervalSec': 60.0},
        'notification': {'title': 'On duty', 'priority': 'default'},
        'ios': {'activityType': 'otherNavigation'},
        'logLevel': 'debug',
      });
    });

    test('LowBattery.off sends null; leaving it out sends nothing', () async {
      reply = (_) => _state;
      await LongPing.setConfig(const Config(lowBattery: LowBattery.off));
      await LongPing.setConfig(const Config(lowBattery: LowBattery(belowPct: 20, intervalSec: 300)));
      await LongPing.setConfig(const Config(debug: true));
      expect(calls[0].arguments, {'lowBattery': null});
      expect(calls[1].arguments, {
        'lowBattery': {'belowPct': 20, 'intervalSec': 300.0},
      });
      expect((calls[2].arguments as Map).containsKey('lowBattery'), isFalse);
    });
  });

  test('parses the state the engine returns', () async {
    reply = (_) => _state;
    final state = await LongPing.getState();
    expect(state.enabled, isTrue);
    expect(state.queueCount, 3);
    expect(state.lastLocationAt, DateTime.fromMillisecondsSinceEpoch(1793016000123, isUtc: true));
    expect(state.lastLocation!.coords.latitude, 43.85);
    expect(state.lastLocation!.coords.altitude, isNull);
    expect(state.lastLocation!.timestamp, DateTime.utc(2026, 10, 26, 12, 0, 0, 123));
    expect(state.lastLocation!.event, LocationEvent.interval);
    expect(state.lastLocation!.battery.level, 0.82);
    expect(state.config.movingIntervalSec, 30);
    expect(state.config.lowBattery, isNull);
    expect(state.config.http!.method, HttpMethod.post);
    expect(state.config.http!.maxBatchSize, 100);
    expect(state.config.persistence!.maxDays, 7);
    expect(state.config.notification!.priority, NotificationPriority.normal);
    expect(state.config.ios!.activityType, IosActivityType.otherNavigation);
    expect(state.config.logMaxDays, 3);
  });

  test('a location round-trips to the upload format', () {
    expect(Location.fromMap(_location).toMap(), _location);
  });

  test('numbers come back as int whether the platform sends int or double', () async {
    reply = (call) => call.method == 'sync' ? 7 : 12.0;
    expect(await LongPing.sync(), 7);
    expect(await LongPing.getQueueCount(), 12);
  });

  test('requestPermission sends the level and maps the status', () async {
    reply = (_) => 3.0;
    expect(await LongPing.requestPermission(PermissionLevel.always), LocationAuthorizationStatus.always);
    expect(calls.single.arguments, 'always');
  });

  test('getCurrentPosition and getLog send named options', () async {
    reply = (call) => call.method == 'getLog' ? 'log' : _location;
    await LongPing.getCurrentPosition(timeoutSec: 10, persist: true, extras: {'stop': 'A'});
    await LongPing.logger.getLog(since: DateTime.fromMillisecondsSinceEpoch(1000), order: LogOrder.desc);
    expect(calls[0].arguments, {
      'timeoutSec': 10.0,
      'persist': true,
      'extras': {'stop': 'A'},
    });
    expect(calls[1].arguments, {'sinceMs': 1000, 'order': 'desc'});
  });

  test('changePace sends a bool', () async {
    reply = (_) => _state;
    await LongPing.changePace(true);
    expect(calls.single.arguments, true);
  });

  test('platform errors become LongPingException with the code', () async {
    reply = (_) => throw PlatformException(code: 'PERMISSION_DENIED', message: 'no permission');
    await expectLater(
      LongPing.start(),
      throwsA(isA<LongPingException>()
          .having((e) => e.code, 'code', LongPingErrorCode.permissionDenied)
          .having((e) => e.message, 'message', 'no permission')),
    );
    reply = (_) => throw PlatformException(code: 'SOMETHING_NEW');
    await expectLater(
      LongPing.stop(),
      throwsA(isA<LongPingException>().having((e) => e.code, 'code', LongPingErrorCode.internal)),
    );
  });

  test('events are routed to their stream by name', () async {
    late MockStreamHandlerEventSink sink;
    var listens = 0;
    var cancels = 0;
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (_, s) {
          sink = s;
          listens++;
        },
        onCancel: (_) => cancels++,
      ),
    );

    final locations = <Location>[];
    final enabled = <bool>[];
    final http = <HttpEvent>[];
    final subs = [
      LongPing.onLocation.listen(locations.add),
      LongPing.onEnabledChange.listen(enabled.add),
      LongPing.onHttp.listen(http.add),
    ];
    await pumpEventQueue();

    sink.success({'event': 'location', 'payload': _location});
    sink.success({
      'event': 'enabledchange',
      'payload': {'enabled': false},
    });
    sink.success({
      'event': 'http',
      'payload': {'status': 200.0, 'ok': true, 'count': 5.0, 'responseText': '{}'},
    });
    await pumpEventQueue();

    expect(locations.single.uuid, _location['uuid']);
    expect(enabled, [false]);
    expect(http.single.count, 5);
    // All streams share one platform subscription.
    expect(listens, 1);

    for (final sub in subs) {
      await sub.cancel();
    }
    await pumpEventQueue();
    expect(cancels, 1);
  });
}
