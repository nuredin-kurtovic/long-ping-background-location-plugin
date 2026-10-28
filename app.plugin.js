// Expo config plugin. With "plugins": ["react-native-long-ping"] in app.json, `npx expo prebuild` and
// EAS Build write the native settings Long Ping needs into the generated ios/ and android/ projects.
// Plain CommonJS with no build step; `expo/config-plugins` comes from the app's own `expo` package.
const { AndroidConfig, createRunOncePlugin, withInfoPlist } = require('expo/config-plugins');

const pkg = require('./package.json');

const WHEN_IN_USE_KEY = 'NSLocationWhenInUseUsageDescription';
const ALWAYS_KEY = 'NSLocationAlwaysAndWhenInUseUsageDescription';
const DEFAULT_WHEN_IN_USE = 'Allow $(PRODUCT_NAME) to use your location.';
const DEFAULT_ALWAYS = 'Allow $(PRODUCT_NAME) to use your location, including when the app is closed.';

const BACKGROUND_LOCATION = 'android.permission.ACCESS_BACKGROUND_LOCATION';
const POST_NOTIFICATIONS = 'android.permission.POST_NOTIFICATIONS';
const IGNORE_BATTERY_OPTIMIZATIONS = 'android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS';

/**
 * @typedef {object} LongPingPluginProps
 * @property {string} [locationWhenInUsePermission] iOS "While Using" prompt text.
 * @property {string} [locationAlwaysAndWhenInUsePermission] iOS "Always" prompt text.
 * @property {boolean} [backgroundLocation=true] false = the app only tracks while it is open: no iOS
 *   `location` background mode or "Always" text, and ACCESS_BACKGROUND_LOCATION is removed on Android.
 * @property {boolean} [ignoreBatteryOptimizationsPermission=false] Declare
 *   REQUEST_IGNORE_BATTERY_OPTIMIZATIONS so `deviceSettings.requestIgnoreBatteryOptimizations()` shows the
 *   direct prompt. Google Play only allows it for some app categories.
 */

/** @type {import('expo/config-plugins').ConfigPlugin<LongPingPluginProps | void>} */
const withLongPing = (config, props) => {
  const {
    locationWhenInUsePermission,
    locationAlwaysAndWhenInUsePermission,
    backgroundLocation = true,
    ignoreBatteryOptimizationsPermission = false,
  } = props || {};

  // A text passed to the plugin wins, then one already in ios.infoPlist, then the default.
  config = withInfoPlist(config, (config) => {
    const plist = config.modResults;
    plist[WHEN_IN_USE_KEY] = locationWhenInUsePermission || plist[WHEN_IN_USE_KEY] || DEFAULT_WHEN_IN_USE;
    if (backgroundLocation) {
      plist[ALWAYS_KEY] = locationAlwaysAndWhenInUsePermission || plist[ALWAYS_KEY] || DEFAULT_ALWAYS;
      const modes = Array.isArray(plist.UIBackgroundModes) ? plist.UIBackgroundModes : [];
      if (!modes.includes('location')) {
        plist.UIBackgroundModes = [...modes, 'location'];
      }
    }
    return config;
  });

  // The library's own manifest brings location, foreground service and boot. The app declares what it
  // asks for itself: the tracking notification on Android 13+, and optionally the battery prompt.
  config = AndroidConfig.Permissions.withPermissions(
    config,
    [POST_NOTIFICATIONS, ignoreBatteryOptimizationsPermission && IGNORE_BATTERY_OPTIMIZATIONS].filter(Boolean),
  );
  if (!backgroundLocation) {
    config = AndroidConfig.Permissions.withBlockedPermissions(config, [BACKGROUND_LOCATION]);
  }

  return config;
};

module.exports = createRunOncePlugin(withLongPing, pkg.name, pkg.version);
