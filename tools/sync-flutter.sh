#!/usr/bin/env bash
# The Flutter package (flutter/) runs the same native engine as the React Native package. A pub.dev package must
# contain every file it builds from, so the engine is copied into flutter/ and the copies are committed.
#
# Change the engine only in android/ and ios/, then run tools/sync-flutter.sh.
# tools/sync-flutter.sh --check (CI) fails if a copy differs from its source.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

# source:destination (directories are mirrored; files deleted at the source are deleted from the copy)
dirs=(
  "android/src/main/java/com/longping/core:flutter/android/src/main/kotlin/com/longping/core"
  "android/src/main/java/com/longping/engine:flutter/android/src/main/kotlin/com/longping/engine"
  "ios/Core:flutter/ios/Classes/Core"
  "ios/Engine:flutter/ios/Classes/Engine"
)
files=(
  "android/src/main/AndroidManifest.xml:flutter/android/src/main/AndroidManifest.xml"
  "android/consumer-rules.pro:flutter/android/consumer-rules.pro"
  "ios/PrivacyInfo.xcprivacy:flutter/ios/Resources/PrivacyInfo.xcprivacy"
  "LICENSE.md:flutter/LICENSE"
)

if [ "${1:-}" = "--check" ]; then
  status=0
  for pair in "${dirs[@]}" "${files[@]}"; do
    src="${pair%%:*}"
    dst="${pair#*:}"
    if ! diff -r "$src" "$dst" >/dev/null 2>&1; then
      echo "$dst differs from $src" >&2
      status=1
    fi
  done
  if [ "$status" -ne 0 ]; then
    echo "Run tools/sync-flutter.sh and commit the result." >&2
  fi
  exit "$status"
fi

for pair in "${dirs[@]}"; do
  src="${pair%%:*}"
  dst="${pair#*:}"
  mkdir -p "$dst"
  rsync -a --delete "$src/" "$dst/"
done
for pair in "${files[@]}"; do
  src="${pair%%:*}"
  dst="${pair#*:}"
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
done
echo "flutter/ engine copies are up to date"
