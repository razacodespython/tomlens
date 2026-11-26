#!/usr/bin/env bash
# Runs the platform-independent unit tests (pure Swift, Foundation only) with
# SwiftPM, so they work on Linux without Xcode. The full suite still runs on
# macOS CI via xcodebuild.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
pure_sources=(
  leanring-buddy/TradingWindowCapturePolicy.swift
  leanring-buddy/TradingWindowCoordinateMapping.swift
)
pure_tests=(
  leanring-buddyTests/TradingWindowCapturePolicyTests.swift
)
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
mkdir -p "$work_dir/Sources/TomLens" "$work_dir/Tests/TomLensTests"
for source_file in "${pure_sources[@]}"; do cp "$repo_root/$source_file" "$work_dir/Sources/TomLens/"; done
for test_file in "${pure_tests[@]}"; do cp "$repo_root/$test_file" "$work_dir/Tests/TomLensTests/"; done
cat > "$work_dir/Package.swift" <<'SWIFT'
// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "TomLens", targets: [
  .target(name: "TomLens", swiftSettings: [.swiftLanguageMode(.v5)]),
  .testTarget(name: "TomLensTests", dependencies: ["TomLens"], swiftSettings: [.swiftLanguageMode(.v5)]),
])
SWIFT
cd "$work_dir" && swift test
