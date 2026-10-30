#!/bin/bash
# Usage: android-test.sh <Swift SDKs path> <Swift SDK id> <triple>
#
# Runs the package's tests, built for `triple`, on the running emulator
# (see android-start-emulator.sh). The test runners and executables go to
# the emulator with the libraries they load beside them: the Swift runtime
# and Foundation from the SDK, and the NDK's C++ library. ServiceFixture goes
# too: the tests that end a process launch it from there. The Example runs
# first, as in the Musl job.
set -euo pipefail
sdks=$1 sdk_id=$2 triple=$3
arch="${triple%%-*}"

adb="$ANDROID_HOME/platform-tools/adb"
sdk="$sdks/$sdk_id.artifactbundle/swift-android"
bin="$(swift build --swift-sdks-path "$sdks" --swift-sdk "$sdk_id" --triple "$triple" --show-bin-path)"

stage="$RUNNER_TEMP/fp-swift-service"
mkdir -p "$stage"
find "$bin" -maxdepth 1 \( -name '*-test-runner' -o -name '*.xctest' -o -name '*.so' \
    -o -name ServiceFixture -o -name Example \) -exec cp -a {} "$stage" \;
cp "$sdk/swift-resources/usr/lib/swift-$arch/android/"*.so "$stage"
cp "$sdk/ndk-sysroot/usr/lib/$arch-linux-android/libc++_shared.so" "$stage"
test -x "$stage/ServiceFixture"
test -x "$stage/Example"
"$adb" push "$stage" /data/local/tmp/

device=/data/local/tmp/fp-swift-service
"$adb" shell "cd $device && ./Example job"
runners="$(cd "$stage" && ls -1 | grep -E -e '-test-runner$' -e '\.xctest$')"
for runner in $runners; do
    echo "== $runner"
    "$adb" shell "cd $device && ./$runner --testing-library swift-testing"
done
