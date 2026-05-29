#!/usr/bin/env bash
# Install Android platform 36 (Flutter 3.44 requirement) + retry debug APK
# with the loopback workaround, and verify the AVD.
set -u
export PATH=/c/flutter/bin:$PATH
SDK=/c/Android/sdk
SDKM="$SDK/cmdline-tools/latest/bin/sdkmanager.bat"
AVDM="$SDK/cmdline-tools/latest/bin/avdmanager.bat"
IMG="system-images;android-35;google_apis;x86_64"
step(){ echo ""; echo "==== $* ===="; }

step "1. Install platform-36 + build-tools 36.0.0"
yes | "$SDKM" --sdk_root="$SDK" "platforms;android-36" "build-tools;36.0.0" 2>&1 | tail -6

step "2. doctor (android)"
flutter doctor 2>&1 | grep -A2 -i 'android toolchain' | head -4

step "3. Ensure AVD exists"
if ! "$AVDM" list avd 2>/dev/null | grep -q holdable_pixel7; then
  echo "creating AVD..."
  echo "no" | "$AVDM" create avd -n holdable_pixel7 -k "$IMG" -d pixel_7 2>&1 | tail -3
fi
echo "--- avdmanager list avd ---"
"$AVDM" list avd 2>/dev/null | grep -E 'Name:|Based on:' | head
echo "--- flutter emulators ---"
flutter emulators 2>&1 | grep -i holdable || echo "(flutter emulators did not list it yet)"

step "4. Build debug APK (daemon off)"
cd "C:/Users/Administrator/Documents/New project/Projects/3D Viewer/Holdable"
flutter build apk --debug 2>&1 | tail -18

step "DONE"
ls -la build/app/outputs/flutter-apk/app-debug.apk 2>&1 || echo "APK STILL MISSING"
