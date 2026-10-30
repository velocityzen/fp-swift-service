#!/bin/bash
# Usage: android-start-emulator.sh <API level>
#
# Starts an x86_64 Android emulator of that API level in the background, and
# returns once it has booted. Uses the runner's Android SDK ($ANDROID_HOME);
# the emulator needs KVM, and room on the disk.
set -euo pipefail
api=$1

echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' |
    sudo tee /etc/udev/rules.d/99-kvm4all.rules
sudo udevadm control --reload-rules
sudo udevadm trigger --name-match=kvm
sudo rm -rf /usr/share/dotnet /opt/ghc /usr/local/.ghcup /opt/hostedtoolcache/CodeQL

image="system-images;android-$api;default;x86_64"
tools="$ANDROID_HOME/cmdline-tools/latest/bin"
yes | "$tools/sdkmanager" --licenses > /dev/null || true
"$tools/sdkmanager" --install emulator platform-tools "platforms;android-$api" "$image"

# avdmanager and the emulator don't agree on a default place for the AVD on
# the runners (one honours XDG_CONFIG_HOME), so both are told.
export ANDROID_AVD_HOME="$HOME/.android/avd"
mkdir -p "$ANDROID_AVD_HOME"
echo no | "$tools/avdmanager" create avd --force --name test --package "$image" --device "Nexus 10"

emulator="$ANDROID_HOME/emulator/emulator"
"$emulator" -accel-check
log="$RUNNER_TEMP/emulator.log"
nohup "$emulator" -avd test -no-window -noaudio -no-boot-anim -no-snapshot -no-metrics \
    -wipe-data -memory 4096 -partition-size 2048 > "$log" 2>&1 &
pid=$!

# Waits for the boot, but stops at once if the emulator exits, and shows
# why.
adb="$ANDROID_HOME/platform-tools/adb"
for _ in $(seq 120); do
    if ! kill -0 "$pid" 2> /dev/null; then
        echo "::error::The emulator exited before it booted."
        cat "$log"
        exit 1
    fi
    booted="$(timeout 10 "$adb" shell getprop sys.boot_completed 2> /dev/null | tr -d '\r' || true)"
    [ "$booted" = 1 ] && exit 0
    sleep 5
done
echo "::error::The emulator did not boot in 10 minutes."
cat "$log"
exit 1
