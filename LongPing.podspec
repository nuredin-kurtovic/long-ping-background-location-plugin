require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "LongPing"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = "https://longping.dev"
  s.license      = { :type => "MIT", :file => "LICENSE.md" }
  s.authors      = "Long Ping"
  s.platforms    = { :ios => "15.1" }
  s.source       = { :git => "https://github.com/nuredin-kurtovic/long-ping-background-location-plugin.git", :tag => s.version.to_s }

  s.source_files  = "ios/LongPing.{h,mm}", "ios/Engine/**/*.swift", "ios/Core/**/*.swift"
  # LongPing.h imports the Objective-C++-only codegen header; keeping it out of the umbrella header stops
  # Swift's import of this module from compiling it as plain Objective-C.
  s.private_header_files = "ios/LongPing.h"
  s.swift_version = "5.9"
  s.frameworks    = "CoreLocation", "UIKit", "Security", "Network"
  # Apple privacy manifest: required-reason API use (UserDefaults) and the location data the plugin handles.
  s.resource_bundles = { "LongPing_privacy" => ["ios/PrivacyInfo.xcprivacy"] }
  s.library       = "sqlite3"

  install_modules_dependencies(s)
end
