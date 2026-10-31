import Flutter
import UIKit

/// Flutter bridge: method channel `long_ping`, event channel `long_ping/events`. Only forwards to
/// LongPingEngine, which runs with or without Flutter (launch resume lives in LongPingLaunch.m). Events go out
/// only while Dart listens; nothing is buffered. Replies and events are delivered on the main thread.
public final class LongPingPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private let engine = LongPingEngine.shared

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = LongPingPlugin()
        let methods = FlutterMethodChannel(name: "long_ping", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: methods)
        let events = FlutterEventChannel(name: "long_ping/events", binaryMessenger: registrar.messenger())
        events.setStreamHandler(instance)
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        engine.removeEventSink(owner: self)
    }

    // MARK: - Events

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        engine.setEventSink({ name, body in
            DispatchQueue.main.async { events(["event": name, "payload": body]) }
        }, owner: self)
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        engine.removeEventSink(owner: self)
        return nil
    }

    // MARK: - Methods

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let settle = Self.settle(result)
        let options = call.arguments as? [String: Any]
        switch call.method {
        case "configure": engine.configure(options, completion: settle)
        case "setConfig": engine.setConfig(options, completion: settle)
        case "start": engine.start(completion: settle)
        case "stop": engine.stop(completion: settle)
        case "getState": engine.getState(completion: settle)
        case "setAuthorization": engine.setAuthorization(options, completion: settle)
        case "clearAuthorization": engine.clearAuthorization(completion: settle)
        case "getCurrentPosition": engine.getCurrentPosition(options, completion: settle)
        case "changePace": engine.changePace((call.arguments as? Bool) ?? false, completion: settle)
        case "sync": engine.sync(completion: settle)
        case "getQueueCount": engine.getQueueCount(completion: settle)
        case "clearQueue": engine.clearQueue(completion: settle)
        case "getProviderState": engine.getProviderState(completion: settle)
        case "requestPermission": engine.requestPermission((call.arguments as? String) ?? "", completion: settle)
        // Android-only concepts; iOS answers per DESIGN.md.
        case "isIgnoringBatteryOptimizations": result(true)
        case "requestIgnoreBatteryOptimizations", "openPowerManagerSettings": result(false)
        case "openAppSettings": engine.openAppSettings(completion: settle)
        case "openLocationSettings": engine.openLocationSettings(completion: settle)
        case "getLog": engine.getLog(options, completion: settle)
        case "clearLog": engine.clearLog(completion: settle)
        default: result(FlutterMethodNotImplemented)
        }
    }

    /// Engine completion (any thread) -> reply on the main thread. A non-nil code is a DESIGN.md error code.
    private static func settle(_ result: @escaping FlutterResult) -> LongPingEngine.Completion {
        return { value, code, message in
            DispatchQueue.main.async {
                if let code {
                    result(FlutterError(code: code, message: message ?? code, details: nil))
                } else {
                    result(value)
                }
            }
        }
    }
}
