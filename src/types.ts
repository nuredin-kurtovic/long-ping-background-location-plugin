// Public types. Field names and defaults mirror DESIGN.md exactly.

export type Accuracy = 'high' | 'balanced' | 'low';
export type LogLevel = 'off' | 'error' | 'warn' | 'info' | 'debug';
export type LocationEvent = 'interval' | 'motionchange' | 'current';

export const AuthorizationStatus = {
  NOT_DETERMINED: 0,
  RESTRICTED: 1,
  DENIED: 2,
  ALWAYS: 3,
  WHEN_IN_USE: 4,
} as const;
export type AuthorizationStatus = (typeof AuthorizationStatus)[keyof typeof AuthorizationStatus];

export type ErrorCode =
  | 'INVALID_CONFIG'
  | 'PERMISSION_DENIED'
  | 'LOCATION_SERVICES_OFF'
  | 'NOT_ENABLED'
  | 'TIMEOUT'
  | 'NO_ACTIVITY'
  | 'INTERNAL';

export interface HttpConfig {
  /** Upload endpoint. null or '' = record locally, never upload. Default null. */
  url?: string | null;
  /** Default 'POST'. */
  method?: 'POST' | 'PUT';
  headers?: Record<string, string>;
  /** Send several records per request. Default true. */
  batch?: boolean;
  /** 1..1000, default 100. */
  maxBatchSize?: number;
  /** 0 = upload as soon as a fix is recorded (default). N = at most one upload every N seconds. */
  uploadIntervalSec?: number;
  /**
   * Where records go in the body. Default 'location' (single) / 'locations' (batch).
   * '.' puts a single record at the body root.
   */
  rootProperty?: string | null;
  /**
   * JSON template for each record, e.g. '{"lat":{{latitude}},"lng":{{longitude}},"at":"{{timestamp}}"}'.
   * Tokens are replaced with raw values; write quotes around string tokens yourself.
   */
  locationTemplate?: string | null;
  /** Merged into the body root of every request. */
  params?: Record<string, unknown>;
  /** Added to every record as "extras". */
  extras?: Record<string, unknown>;
  /** 5..120, default 30. */
  timeoutSec?: number;
}

export interface Config {
  /** Seconds between fixes while moving. 1..86400, default 30. */
  movingIntervalSec?: number;
  /** Seconds between fixes while parked. 1..86400, default 180. */
  parkedIntervalSec?: number;
  /** Default 'high'. */
  accuracy?: Accuracy;
  /** Fixes less accurate than this (meters) are not recorded. 0 = accept all. Default 100. */
  minAccuracyM?: number;
  /** Parked after staying within stopRadiusM for this long. 30..86400, default 300. */
  stopTimeoutSec?: number;
  /** 10..10000, default 75. */
  stopRadiusM?: number;
  /** Speed (m/s) that counts as moving. 0.5..100, default 3. */
  movingSpeedMps?: number;
  /** Never switch to parked. Default false. */
  disableStopDetection?: boolean;
  /** When not charging and below belowPct, use at least intervalSec. Default null (off). */
  lowBattery?: { belowPct: number; intervalSec: number } | null;
  http?: HttpConfig;
  persistence?: {
    /** 1..1000000, default 10000. */
    maxRecords?: number;
    /** 1..365, default 7. */
    maxDays?: number;
  };
  /** Android: restart after a reboot or app update. (iOS relaunches on movement whenever tracking is on.) Default true. */
  startOnBoot?: boolean;
  /** Stop tracking when the app is swiped away. Default false. */
  stopOnTerminate?: boolean;
  /**
   * Apply the server's overrides (`long_ping.config` in upload responses). They are kept on the device across
   * configure() / setConfig() until `long_ping.reset`; false keeps them stored but unused. Only the app sets this.
   * Default true.
   */
  remoteConfig?: boolean;
  /** Android foreground-service notification. */
  notification?: {
    title?: string;
    text?: string;
    channelName?: string;
    /** Drawable or mipmap resource name. Default: app icon. */
    smallIcon?: string | null;
    priority?: 'low' | 'default' | 'high';
  };
  ios?: {
    showsBackgroundLocationIndicator?: boolean;
    activityType?: 'automotive' | 'otherNavigation' | 'fitness' | 'other';
  };
  /** Default 'info'. */
  logLevel?: LogLevel;
  /** 1..30, default 3. */
  logMaxDays?: number;
  /** Android: notification shows last fix age and queue size. Default false. */
  debug?: boolean;
}

/** Config as the engine holds it: every key filled in. */
export type ResolvedConfig = Required<Omit<Config, 'http' | 'persistence' | 'notification' | 'ios'>> & {
  http: Required<HttpConfig>;
  persistence: Required<NonNullable<Config['persistence']>>;
  notification: Required<NonNullable<Config['notification']>>;
  ios: Required<NonNullable<Config['ios']>>;
};

export interface Coords {
  latitude: number;
  longitude: number;
  /** Horizontal accuracy, meters. */
  accuracy: number;
  /** m/s, -1 unknown. */
  speed: number;
  /** Degrees, -1 unknown. */
  heading: number;
  /** Meters, null unknown. */
  altitude: number | null;
}

export interface Location {
  uuid: string;
  /** ISO 8601 UTC with milliseconds. */
  timestamp: string;
  event: LocationEvent;
  is_moving: boolean;
  coords: Coords;
  /** level 0..1 (-1 unknown). */
  battery: { level: number; is_charging: boolean };
  mock: boolean;
  extras?: Record<string, unknown>;
}

export interface State {
  enabled: boolean;
  isMoving: boolean;
  lastLocation: Location | null;
  lastLocationAt: number | null;
  queueCount: number;
  authorizationRequired: boolean;
  /** The config in effect: your app's config with the server's overrides on top. */
  config: ResolvedConfig;
}

export interface ProviderState {
  /** Location services switched on. */
  enabled: boolean;
  gps: boolean;
  network: boolean;
  status: AuthorizationStatus;
  accuracyAuthorization: 'full' | 'reduced';
  powerSaveMode: boolean;
  /** Android only; always true on iOS. */
  ignoringBatteryOptimizations: boolean;
}

export interface Authorization {
  accessToken: string;
  refreshToken?: string;
  /** POSTed with refreshPayload on a 401/403; reply must carry access_token (and optionally refresh_token). */
  refreshUrl?: string;
  /** Default {"refresh_token": "{{refreshToken}}"}. */
  refreshPayload?: Record<string, string>;
  refreshHeaders?: Record<string, string>;
}

export interface CurrentPositionOptions {
  /** Default 30. */
  timeoutSec?: number;
  /** Accept a cached fix this young. Default 0. */
  maximumAgeSec?: number;
  accuracy?: Accuracy;
  /** Record and upload the fix (event 'current'). Default false. */
  persist?: boolean;
  extras?: Record<string, unknown>;
}

export interface GetLogOptions {
  /** Default: 24 hours ago. */
  sinceMs?: number;
  /** Default 1000. */
  limit?: number;
  order?: 'asc' | 'desc';
}

export interface MotionChangeEvent {
  isMoving: boolean;
  location: Location;
}

export interface HttpEvent {
  /** 0 = network error. */
  status: number;
  ok: boolean;
  count: number;
  responseText: string;
}

export interface AuthorizationEvent {
  status: number;
  error: string | null;
}

export interface EnabledChangeEvent {
  enabled: boolean;
}

export interface ErrorEvent {
  code: ErrorCode;
  message: string;
}

export interface Subscription {
  remove(): void;
}
