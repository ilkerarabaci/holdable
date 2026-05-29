#!/usr/bin/env bash
# Install JDK 17 (AGP-recommended) and retry the debug APK. JDK 21 on this
# Windows box fails Gradle's NIO loopback pipe (AF_UNIX connect = "Invalid
# argument"); JDK 17 uses the legacy selector and is the supported AGP JDK.
set -u
export PATH=/c/flutter/bin:$PATH
step(){ echo ""; echo "==== $* ===="; }

step "1. Install Microsoft OpenJDK 17"
winget install --id Microsoft.OpenJDK.17 -e --silent --accept-source-agreements --accept-package-agreements 2>&1 | tail -6

step "2. Locate JDK 17"
JDK=$(ls -d "/c/Program Files/Microsoft/jdk-17"* 2>/dev/null | head -1)
echo "JDK17 = $JDK"
if [ -z "$JDK" ]; then echo "JDK 17 not found after install"; exit 1; fi
"$JDK/bin/java.exe" -version 2>&1 | head -2

step "3. Point Flutter/Gradle at JDK 17"
WINJDK=$(cygpath -w "$JDK" 2>/dev/null || echo "$JDK")
flutter config --jdk-dir "$WINJDK" 2>&1 | tail -2

step "4. Build debug APK"
cd "C:/Users/Administrator/Documents/New project/Projects/3D Viewer/Holdable"
flutter build apk --debug 2>&1 | tail -18

step "DONE"
ls -la build/app/outputs/flutter-apk/app-debug.apk 2>&1 || echo "APK STILL MISSING"
