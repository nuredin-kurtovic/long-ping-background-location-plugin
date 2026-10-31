// Runs against the real native engine (no permission needed): every call crosses the bridge both ways.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:long_ping/long_ping.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'configure, setConfig and getState round-trip through the engine',
    (tester) async {
      var state = await LongPing.configure(
        const Config(
          movingIntervalSec: 15,
          parkedIntervalSec: 120,
          accuracy: Accuracy.balanced,
          lowBattery: LowBattery(belowPct: 20, intervalSec: 300),
          http: HttpConfig(url: '', headers: {'X-Test': '1'}, maxBatchSize: 50),
          notification: NotificationConfig(
            priority: NotificationPriority.normal,
          ),
          ios: IosConfig(activityType: IosActivityType.fitness),
        ),
      );
      expect(state.enabled, isFalse);
      expect(state.config.movingIntervalSec, 15);
      expect(state.config.accuracy, Accuracy.balanced);
      expect(state.config.lowBattery?.belowPct, 20);
      expect(state.config.http?.url, isNull);
      expect(state.config.http?.headers, {'X-Test': '1'});
      expect(state.config.http?.maxBatchSize, 50);
      expect(state.config.notification?.priority, NotificationPriority.normal);
      expect(state.config.ios?.activityType, IosActivityType.fitness);
      // Defaults fill everything that was left out.
      expect(state.config.stopRadiusM, 75);
      expect(state.config.persistence?.maxRecords, 10000);

      state = await LongPing.setConfig(
        const Config(movingIntervalSec: 20, lowBattery: LowBattery.off),
      );
      expect(state.config.movingIntervalSec, 20);
      expect(state.config.parkedIntervalSec, 120);
      expect(state.config.lowBattery, isNull);

      state = await LongPing.getState();
      expect(state.config.movingIntervalSec, 20);
    },
  );

  testWidgets('invalid config is rejected with INVALID_CONFIG naming the key', (
    tester,
  ) async {
    await expectLater(
      LongPing.configure(const Config(http: HttpConfig(url: 'not a url'))),
      throwsA(
        isA<LongPingException>()
            .having((e) => e.code, 'code', LongPingErrorCode.invalidConfig)
            .having((e) => e.message, 'message', startsWith('http.url')),
      ),
    );
  });

  testWidgets('queue, provider state, settings and log answer', (tester) async {
    await LongPing.configure(const Config());
    await LongPing.clearQueue();
    expect(await LongPing.getQueueCount(), 0);

    final provider = await LongPing.getProviderState();
    expect(LocationAuthorizationStatus.values, contains(provider.status));

    expect(
      await LongPing.deviceSettings.isIgnoringBatteryOptimizations(),
      isA<bool>(),
    );

    final log = await LongPing.logger.getLog(limit: 50);
    expect(log, contains('configure'));
  });

  testWidgets('start without permission is refused, not prompted', (
    tester,
  ) async {
    final provider = await LongPing.getProviderState();
    if (provider.status == LocationAuthorizationStatus.always ||
        provider.status == LocationAuthorizationStatus.whenInUse) {
      markTestSkipped('location permission already granted on this device');
      return;
    }
    await expectLater(
      LongPing.start(),
      throwsA(
        isA<LongPingException>().having(
          (e) => e.code,
          'code',
          LongPingErrorCode.permissionDenied,
        ),
      ),
    );
    expect((await LongPing.getState()).enabled, isFalse);
  });
}
