require "yaml"

pubspec = YAML.load_file(File.join(__dir__, "..", "pubspec.yaml"))

Pod::Spec.new do |s|
  s.name         = "long_ping"
  s.version      = pubspec["version"]
  s.summary      = pubspec["description"]
  s.homepage     = "https://longping.dev"
  s.license      = { :type => "MIT", :file => "../LICENSE" }
  s.authors      = "Long Ping"
  s.source       = { :path => "." }
  s.platform     = :ios, "15.1"

  # Classes/Core and Classes/Engine are the React Native package's iOS engine, copied in by
  # tools/sync-flutter.sh; LongPingPlugin.swift and LongPingLaunch.m are the Flutter bridge.
  s.source_files = "Classes/**/*.{swift,m}"
  s.dependency "Flutter"
  s.swift_version = "5.9"
  s.frameworks    = "CoreLocation", "UIKit", "Security", "Network"
  s.library       = "sqlite3"
  # Apple privacy manifest: required-reason API use (UserDefaults) and the location data the plugin handles.
  s.resource_bundles = { "long_ping_privacy" => ["Resources/PrivacyInfo.xcprivacy"] }

  # Flutter.framework does not contain an i386 slice.
  s.pod_target_xcconfig = { "DEFINES_MODULE" => "YES", "EXCLUDED_ARCHS[sdk=iphonesimulator*]" => "i386" }
end
