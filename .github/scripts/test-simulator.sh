#!/bin/bash
# Usage: test-simulator.sh <device name>
#
# Runs the package's tests on the first simulator whose name contains
# `device name` and that Xcode can test on, then prints how many ran:
# `xcodebuild -quiet` prints none. Fails if none ran, or any was skipped.
set -euo pipefail
device=$1

# `-showdestinations` lists the simulators this Xcode can test on, each with
# its architecture and OS. `simctl` also lists devices it can't, such as a
# watch model the selected Xcode has no architecture for.
line="$(xcodebuild -showdestinations -scheme fp-swift-service-Package 2>/dev/null |
    sed '/Ineligible destinations/,$d' |
    grep -m1 -E "platform:[A-Za-z]+ Simulator, arch:arm64, id:[0-9A-F-]+, OS:[0-9.]+, name:[^}]*$device" || true)"
if [ -z "$line" ]; then
    echo "::error::No simulator named like \"$device\" that Xcode can test on:"
    xcrun simctl list devices available
    exit 1
fi
udid="$(echo "$line" | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}')"
echo "Simulator: $line"

results="$RUNNER_TEMP/tests.xcresult"
rm -rf "$results"
status=0
xcodebuild test -quiet -scheme fp-swift-service-Package -destination "id=$udid,arch=arm64" \
    -resultBundlePath "$results" || status=$?

# The counts, and each failure's message, which `-quiet` leaves out.
xcrun xcresulttool get test-results summary --path "$results" --compact | python3 -c '
import json, sys
summary = json.load(sys.stdin)
total, skipped = summary["totalTestCount"], summary["skippedTests"]
print(f"{total} tests: {summary['"'"'passedTests'"'"']} passed, {skipped} skipped, {summary['"'"'failedTests'"'"']} failed")
for failure in summary.get("testFailures", []):
    print(f"::error::{failure.get('"'"'testName'"'"')}: {failure.get('"'"'failureText'"'"')}")
sys.exit(0 if total > 0 and skipped == 0 else 1)
'
exit "$status"
