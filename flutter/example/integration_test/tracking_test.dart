// End to end: real fixes, events, the native queue and uploads. Needs location permission and a moving GPS
// feed, set up before the run:
//
//   iOS simulator:
//     xcrun simctl privacy <udid> grant location-always com.longping.longPingExample
//     xcrun simctl location <udid> start --speed=15 --interval=1 43.8563,18.4131 43.8650,18.4400
//   Android emulator:
//     adb shell pm grant com.longping.long_ping_example android.permission.ACCESS_FINE_LOCATION
//     a 1 Hz `geo fix` feed on the emulator console (tools/e2e/ctl.mjs drive)
//
// Uploads go to an HTTP server inside the test app, so the whole path from fix to server is covered.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:long_ping/long_ping.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('tracks on the clock, emits, queues and uploads', (tester) async {
    final provider = await LongPing.getProviderState();
    if (provider.status != LocationAuthorizationStatus.always &&
        provider.status != LocationAuthorizationStatus.whenInUse) {
      markTestSkipped(
        'location permission not granted (see the top of this file)',
      );
      return;
    }

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final records = <Map<String, Object?>>[];
    server.listen((request) async {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, Object?>;
      records.addAll((body['locations'] as List).cast<Map<String, Object?>>());
      request.response
        ..statusCode = 200
        ..write('{}');
      await request.response.close();
    });

    final locations = <Location>[];
    final uploads = <HttpEvent>[];
    final enabled = <bool>[];
    final subscriptions = [
      LongPing.onLocation.listen(locations.add),
      LongPing.onHttp.listen(uploads.add),
      LongPing.onEnabledChange.listen(enabled.add),
    ];
    addTearDown(() async {
      await LongPing.stop();
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      await server.close(force: true);
    });

    await LongPing.configure(
      Config(
        movingIntervalSec: 2,
        parkedIntervalSec: 2,
        minAccuracyM: 0,
        disableStopDetection: true,
        http: HttpConfig(
          url: 'http://127.0.0.1:${server.port}/locations',
          batch: true,
        ),
      ),
    );
    await LongPing.clearQueue();

    final started = await LongPing.start();
    expect(started.enabled, isTrue);

    await _until(
      '4 fixes and a successful upload',
      () => locations.length >= 4 && uploads.any((e) => e.ok),
    );

    // On the clock: interval fixes about 2 s apart.
    final interval = locations
        .where((l) => l.event == LocationEvent.interval)
        .toList();
    expect(interval.length, greaterThanOrEqualTo(2));
    for (var i = 1; i < interval.length; i++) {
      final gap = interval[i].timestamp
          .difference(interval[i - 1].timestamp)
          .inMilliseconds;
      expect(
        gap,
        inInclusiveRange(1000, 4000),
        reason: 'gap between fixes $i-1 and $i',
      );
    }

    // A one-off fix, recorded with extras, reaches the server too.
    final current = await LongPing.getCurrentPosition(
      persist: true,
      extras: {'source': 'e2e'},
    );
    expect(current.event, LocationEvent.current);
    await LongPing.sync();
    await _until(
      'the current fix uploaded',
      () => records.any((r) => r['uuid'] == current.uuid),
    );

    // What the server received is exactly what Dart was given.
    final uploaded = records.firstWhere((r) => r['uuid'] == current.uuid);
    expect(uploaded, equals(current.toMap()));
    expect(uploaded['extras'], {'source': 'e2e'});
    final first = records.firstWhere((r) => r['uuid'] == locations.first.uuid);
    expect(first, equals(locations.first.toMap()));

    final state = await LongPing.getState();
    expect(state.lastLocation, isNotNull);

    final stopped = await LongPing.stop();
    expect(stopped.enabled, isFalse);
    await _until('enabledchange false', () => enabled.contains(false));

    final log = await LongPing.logger.getLog(limit: 500);
    expect(log, isNotEmpty);
  });
}

Future<void> _until(
  String what,
  bool Function() done, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}
