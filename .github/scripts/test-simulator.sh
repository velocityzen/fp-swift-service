#!/bin/bash
# Usage: test-simulator.sh <device name>
#
# Runs the package's tests on the first available simulator whose name
# contains `device name`, then prints how many ran: `xcodebuild -quiet`
# prints none. Fails if none ran, or any was skipped.
set -euo pipefail
device=$1

line="$(xcrun simctl list devices available | grep -m1 "$device")"
udid="$(echo "$line" | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}')"
echo "Simulator: $line"

results="$RUNNER_TEMP/tests.xcresult"
rm -rf "$results"
xcodebuild test -quiet -scheme fp-swift-service-Package -destination "id=$udid,arch=arm64" \
    -resultBundlePath "$results"

xcrun xcresulttool get test-results summary --path "$results" --compact | python3 -c '
import json, sys
summary = json.load(sys.stdin)
total, passed, skipped = summary["totalTestCount"], summary["passedTests"], summary["skippedTests"]
print(f"{total} tests: {passed} passed, {skipped} skipped, {summary['"'"'failedTests'"'"']} failed")
sys.exit(0 if total > 0 and skipped == 0 else 1)
'
