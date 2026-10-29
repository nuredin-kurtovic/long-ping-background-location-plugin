import { NativeEventEmitter } from 'react-native';
import NativeLongPing from './NativeLongPing';
import type {
  Authorization,
  AuthorizationEvent,
  AuthorizationStatus,
  Config,
  CurrentPositionOptions,
  EnabledChangeEvent,
  ErrorEvent,
  GetLogOptions,
  HttpEvent,
  Location,
  MotionChangeEvent,
  ProviderState,
  ResolvedConfig,
  State,
  Subscription,
} from './types';

export * from './types';

const emitter = new NativeEventEmitter(NativeLongPing as any);

const listen =
  <T>(event: string) =>
  (callback: (payload: T) => void): Subscription =>
    emitter.addListener(event, callback as (payload: any) => void);

const LongPing = {
  /**
   * Replace your app's config (defaults + given). Server overrides (`long_ping.config`) stay on top until
   * `long_ping.reset`. Safe on every launch: never starts, stops or prompts.
   */
  configure: (config: Config): Promise<State> => NativeLongPing.configure(config) as Promise<State>,
  /** Merge into your app's config and apply it live. Server overrides stay on top. */
  setConfig: (config: Config): Promise<State> => NativeLongPing.setConfig(config) as Promise<State>,
  /** Start tracking. Rejects PERMISSION_DENIED or LOCATION_SERVICES_OFF; never prompts. */
  start: (): Promise<State> => NativeLongPing.start() as Promise<State>,
  /** Stop tracking. Queued records still upload. */
  stop: (): Promise<State> => NativeLongPing.stop() as Promise<State>,
  getState: (): Promise<State> => NativeLongPing.getState() as Promise<State>,

  /** Store upload credentials (secure storage) and retry any held uploads. */
  setAuthorization: (auth: Authorization): Promise<void> => NativeLongPing.setAuthorization(auth),
  clearAuthorization: (): Promise<void> => NativeLongPing.clearAuthorization(),

  getCurrentPosition: (options: CurrentPositionOptions = {}): Promise<Location> =>
    NativeLongPing.getCurrentPosition(options) as Promise<Location>,
  /** Force moving (true) or parked (false) now. */
  changePace: (isMoving: boolean): Promise<State> => NativeLongPing.changePace(isMoving) as Promise<State>,

  /** Upload the queue now. Resolves the number of records uploaded. */
  sync: (): Promise<number> => NativeLongPing.sync(),
  getQueueCount: (): Promise<number> => NativeLongPing.getQueueCount(),
  clearQueue: (): Promise<void> => NativeLongPing.clearQueue(),

  getProviderState: (): Promise<ProviderState> => NativeLongPing.getProviderState() as Promise<ProviderState>,
  /** The only call that shows a permission dialog. Show your own rationale first. */
  requestPermission: (level: 'whenInUse' | 'always'): Promise<AuthorizationStatus> =>
    NativeLongPing.requestPermission(level) as Promise<AuthorizationStatus>,

  deviceSettings: {
    isIgnoringBatteryOptimizations: (): Promise<boolean> => NativeLongPing.isIgnoringBatteryOptimizations(),
    requestIgnoreBatteryOptimizations: (): Promise<boolean> => NativeLongPing.requestIgnoreBatteryOptimizations(),
    openPowerManagerSettings: (): Promise<boolean> => NativeLongPing.openPowerManagerSettings(),
    openAppSettings: (): Promise<boolean> => NativeLongPing.openAppSettings(),
    openLocationSettings: (): Promise<boolean> => NativeLongPing.openLocationSettings(),
  },

  logger: {
    getLog: (options: GetLogOptions = {}): Promise<string> => NativeLongPing.getLog(options),
    clear: (): Promise<void> => NativeLongPing.clearLog(),
  },

  onLocation: listen<Location>('location'),
  onMotionChange: listen<MotionChangeEvent>('motionchange'),
  onHttp: listen<HttpEvent>('http'),
  onProviderChange: listen<ProviderState>('providerchange'),
  onAuthorization: listen<AuthorizationEvent>('authorization'),
  onEnabledChange: listen<EnabledChangeEvent>('enabledchange'),
  onConfigChange: listen<ResolvedConfig>('configchange'),
  onError: listen<ErrorEvent>('error'),
};

export default LongPing;
