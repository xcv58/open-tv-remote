#!/bin/sh
# Offline host tests. All wake datagrams and WebSockets use inert test substitutes.
set -eu
cd "$(dirname "$0")/.."
package="$PWD/build/wake-tests"
mkdir -p "$package/Sources/WakeCore" "$package/Tests/WakeCoreTests"
cp Sources/Core/RemoteKey.swift Sources/Core/TVDevice.swift Sources/Core/TVDriver.swift \
   Sources/Drivers/LGDriver.swift Sources/Net/WakeOnLAN.swift Tests/Support/WakeTransportStubs.swift \
   "$package/Sources/WakeCore/"
# Also works when composed locally with the independent joystick/cursor PRs.
for optional in Sources/Core/JoystickInput.swift Sources/Core/CursorInput.swift; do
    if [ -f "$optional" ]; then cp "$optional" "$package/Sources/WakeCore/"; fi
done
cp Tests/LGWakeTests.swift "$package/Tests/WakeCoreTests/"
cat > "$package/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "WakeCore", platforms: [.macOS(.v14)], targets: [
    .target(name: "WakeCore"),
    .testTarget(name: "WakeCoreTests", dependencies: ["WakeCore"])
], swiftLanguageModes: [.v5])
PACKAGE
swift test --package-path "$package" --scratch-path "$package/.build/out" --jobs 2
