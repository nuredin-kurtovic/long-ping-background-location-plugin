import 'dart:async';

import 'package:flutter/material.dart';
import 'package:long_ping/long_ping.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Long Ping',
    theme: ThemeData(colorSchemeSeed: const Color(0xFF1F6FEB)),
    darkTheme: ThemeData(
      colorSchemeSeed: const Color(0xFF1F6FEB),
      brightness: Brightness.dark,
    ),
    home: const TrackingScreen(),
  );
}

/// Tracking state, the last fix and an event log, with a button for every command. Records stay on the
/// device (no http.url): set one in [_config] to see uploads.
class TrackingScreen extends StatefulWidget {
  const TrackingScreen({super.key});

  @override
  State<TrackingScreen> createState() => _TrackingScreenState();
}

class _TrackingScreenState extends State<TrackingScreen> {
  static const _config = Config(
    movingIntervalSec: 10,
    parkedIntervalSec: 60,
    notification: NotificationConfig(
      title: 'Long Ping example',
      text: 'Recording your location',
    ),
    logLevel: LogLevel.debug,
  );
  static const _logTail = 50;

  final _subscriptions = <StreamSubscription<Object?>>[];
  final _log = <String>[];
  LongPingState? _state;
  String? _busy;

  @override
  void initState() {
    super.initState();
    _subscriptions.addAll([
      LongPing.onLocation.listen(
        (location) =>
            _event('location ${location.event.name}: ${location.coords}'),
      ),
      LongPing.onMotionChange.listen(
        (event) => _event(event.isMoving ? 'moving' : 'parked'),
      ),
      LongPing.onHttp.listen(
        (event) => _event('upload ${event.status}: ${event.count} records'),
      ),
      LongPing.onEnabledChange.listen(
        (enabled) => _event(enabled ? 'tracking on' : 'tracking off'),
      ),
      LongPing.onProviderChange.listen(
        (state) =>
            _event('provider: ${state.status.name}, on=${state.enabled}'),
      ),
      LongPing.onError.listen(
        (error) => _event('error ${error.code.wire}: ${error.message}'),
      ),
    ]);
    // Safe on every launch: never starts, stops or prompts.
    _run('configure', () => LongPing.configure(_config));
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    super.dispose();
  }

  void _event(String text) {
    final time = TimeOfDay.now().format(context);
    setState(() {
      _log.insert(0, '$time  $text');
      if (_log.length > _logTail) _log.removeLast();
    });
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final state = await LongPing.getState();
    if (mounted) setState(() => _state = state);
  }

  Future<void> _run(String label, Future<Object?> Function() action) async {
    setState(() => _busy = label);
    try {
      final result = await action();
      if (result is LongPingState) {
        _state = result;
      } else if (result != null) {
        _event('$label: $result');
      }
      await _refresh();
    } on LongPingException catch (e) {
      _event('$label failed: ${e.code.wire} ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _showLog() async {
    final text = await LongPing.logger.getLog(limit: 200, order: LogOrder.desc);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        builder: (context, controller) => SingleChildScrollView(
          controller: controller,
          padding: const EdgeInsets.all(16),
          child: SelectableText(
            text.isEmpty ? 'No log lines yet.' : text,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final last = state?.lastLocation;
    final actions = <(String, Future<Object?> Function())>[
      ('Permission', () => LongPing.requestPermission(PermissionLevel.always)),
      ('Start', LongPing.start),
      ('Stop', LongPing.stop),
      ('Moving', () => LongPing.changePace(true)),
      ('Parked', () => LongPing.changePace(false)),
      ('Locate + save', () => LongPing.getCurrentPosition(persist: true)),
      ('Sync', LongPing.sync),
      ('Settings', LongPing.deviceSettings.openAppSettings),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Long Ping'),
        actions: [
          IconButton(
            onPressed: _showLog,
            icon: const Icon(Icons.article_outlined),
            tooltip: 'Log',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    state == null
                        ? 'Loading…'
                        : (state.enabled
                              ? (state.isMoving
                                    ? 'Tracking: moving'
                                    : 'Tracking: parked')
                              : 'Stopped'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    last == null
                        ? 'No fix yet'
                        : '${last.coords.latitude.toStringAsFixed(5)}, ${last.coords.longitude.toStringAsFixed(5)}'
                              '  ±${last.coords.accuracy.round()} m',
                  ),
                  if (last != null) Text('at ${last.timestamp.toLocal()}'),
                  if (state != null) Text('Queued: ${state.queueCount}'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (label, action) in actions)
                FilledButton.tonal(
                  onPressed: _busy == null ? () => _run(label, action) : null,
                  child: Text(label),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text('Events', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          if (_log.isEmpty) const Text('Nothing yet.'),
          for (final line in _log)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(line),
            ),
        ],
      ),
    );
  }
}
