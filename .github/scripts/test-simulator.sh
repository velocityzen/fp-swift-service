#!/bin/bash
# Usage: test-simulator.sh <device name>
#
# Runs the package's tests on the first simulator whose name contains
# `device name`, that Xcode can test on and that boots, then prints how many
# ran: `xcodebuild -quiet` prints none. Fails if none ran, or any was skipped.
set -euo pipefail
device=$1

# Whether some runtime disk image is still being copied, mounted or deleted.
unsettled() {
    xcrun simctl runtime list | grep -E '\((Copying|Deleting|Mounting|Staging|Verifying|Processing)\)'
}

# Boots the first simulator named like `device` that Xcode can test on, and prints its id. `-showdestinations` lists the simulators this Xcode can test on, each with its architecture and OS; `simctl` also lists devices it can't, such as a watch model the selected Xcode has no architecture for. Even a listed one can have a runtime that isn't loaded: Xcode then sees "watchOS Simulator (null)" and runs nothing. Booting loads it, or fails.
boot() {
    local line id booted
    xcodebuild -showdestinations -scheme fp-swift-service-Package 2>/dev/null |
        sed '/Ineligible destinations/,$d' |
        grep -E "platform:[A-Za-z]+ Simulator, arch:arm64, id:[0-9A-F-]+, OS:[0-9.]+, name:[^}]*$device" |
        while IFS= read -r line; do
            id="$(echo "$line" | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}')"
            if booted="$(xcrun simctl bootstatus "$id" -b 2>&1)"; then
                echo "Simulator: $line" >&2
                echo "$id"
                return
            fi
            echo "Could not boot: $line" >&2
            echo "$booted" | tail -3 >&2
        done
}

# The xcode-27 image can have a watchOS runtime Xcode can't use: asking for destinations then starts a repair, a new image "Copying" and the old one "Deleting", and until it is done no watch boots. So each try waits for the images to settle first, for 20 minutes in all.
udid=""
deadline=$((SECONDS + 1200))
while [ -z "$udid" ] && [ "$SECONDS" -lt "$deadline" ]; do
    while [ "$SECONDS" -lt "$deadline" ] && images="$(unsettled)"; do
        echo "Waiting for runtime disk images to settle:"
        echo "$images"
        sleep 15
    done
    udid="$(boot || true)"
    if [ -z "$udid" ] && [ "$SECONDS" -lt "$deadline" ]; then
        echo "No simulator named like \"$device\" booted; trying again."
        sleep 15
    fi
done
if [ -z "$udid" ]; then
    echo "::error::No simulator named like \"$device\" that Xcode can test on and that boots:"
    xcrun simctl list devices available
    xcrun simctl list runtimes
    xcrun simctl runtime list
    exit 1
fi

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
