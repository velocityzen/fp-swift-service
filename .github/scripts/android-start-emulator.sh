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
"$tools/sdkmanager" --install emulator platform-tools "$image"
echo no | "$tools/avdmanager" create avd --force --name test --package "$image"
nohup "$ANDROID_HOME/emulator/emulator" -avd test -no-window -noaudio -no-boot-anim \
    -no-snapshot -no-metrics -memory 4096 -partition-size 2048 > "$RUNNER_TEMP/emulator.log" 2>&1 &

adb="$ANDROID_HOME/platform-tools/adb"
"$adb" wait-for-device
for _ in $(seq 120); do
    [ "$("$adb" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && exit 0
    sleep 5
done
cat "$RUNNER_TEMP/emulator.log"
exit 1
