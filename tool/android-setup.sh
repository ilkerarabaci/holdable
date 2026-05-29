#!/usr/bin/env bash
# One-shot Android SDK + emulator + debug-APK setup for Holdable (Windows/Git-Bash).
# Logged step-by-step; safe to re-run (sdkmanager is idempotent).
set -u
export PATH=/c/flutter/bin:$PATH
SDK=/c/Android/sdk
API=35
IMG="system-images;android-${API};google_apis;x86_64"
step(){ echo ""; echo "==== $* ===="; }

step "1. Download command-line tools"
mkdir -p "$SDK" /tmp/clt
if [ ! -f "$SDK/cmdline-tools/latest/bin/sdkmanager.bat" ]; then
  curl -L -o /tmp/clt/clt.zip \
    https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip || { echo "DOWNLOAD FAILED"; exit 1; }
  rm -rf /tmp/clt/cmdline-tools
  unzip -q /tmp/clt/clt.zip -d /tmp/clt
  mkdir -p "$SDK/cmdline-tools/latest"
  cp -r /tmp/clt/cmdline-tools/* "$SDK/cmdline-tools/latest/"
fi
SDKM="$SDK/cmdline-tools/latest/bin/sdkmanager.bat"
AVDM="$SDK/cmdline-tools/latest/bin/avdmanager.bat"
echo "sdkmanager: $SDKM"

step "2. Accept licenses"
yes | "$SDKM" --sdk_root="$SDK" --licenses >/dev/null 2>&1 || echo "license step returned non-zero (often fine)"

step "3. Install platform-tools, platform $API, build-tools, emulator, system image"
"$SDKM" --sdk_root="$SDK" "platform-tools" "platforms;android-${API}" "build-tools;${API}.0.0" "emulator" "$IMG" 2>&1 | tail -8

step "4. Point Flutter at the SDK"
flutter config --android-sdk "C:\\Android\\sdk" 2>&1 | tail -2

step "5. flutter doctor (android)"
flutter doctor 2>&1 | grep -A3 -i android | head -8

step "6. Create AVD (Pixel 7, API $API)"
if ! "$AVDM" list avd 2>/dev/null | grep -q holdable_pixel7; then
  echo "no" | "$AVDM" create avd -n holdable_pixel7 -k "$IMG" -d pixel_7 2>&1 | tail -4
else
  echo "AVD holdable_pixel7 already exists"
fi
flutter emulators 2>&1 | tail -6

step "7. Build debug APK (verification)"
cd "C:/Users/Administrator/Documents/New project/Projects/3D Viewer/Holdable"
flutter build apk --debug 2>&1 | tail -15

step "DONE"
ls -la build/app/outputs/flutter-apk/app-debug.apk 2>&1 || echo "APK not found — check log above"
