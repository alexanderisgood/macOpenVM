#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration=${1:-debug}
case "$configuration" in debug|release) ;; *) echo 'Use debug or release.'; exit 2;; esac
build_options=()
if test -n "${MACOPENVM_BUILD_JOBS:-}"; then
  [[ "$MACOPENVM_BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] || { echo 'Build jobs must be a positive integer.'; exit 2; }
  build_options=(--jobs "$MACOPENVM_BUILD_JOBS")
fi
mkdir -p .build
build_snapshot=$(mktemp "$PWD/.build/macopenvm-inputs.XXXXXX")
trap 'rm -f "$build_snapshot"' EXIT
python3 scripts/build_manifest.py snapshot --snapshot "$build_snapshot"
./scripts/swift.sh build --configuration "$configuration" "${build_options[@]}"
binary_directory=$(./scripts/swift.sh build --configuration "$configuration" "${build_options[@]}" --show-bin-path)
mkdir -p build/macOpenVM.app/Contents/MacOS build/macOpenVM.app/Contents/Resources build/bin
cp "$binary_directory/macOpenVMDesktop" build/macOpenVM.app/Contents/MacOS/macOpenVM
cp LICENSE NOTICE build/macOpenVM.app/Contents/Resources/
cp packaging/PrivacyInfo.xcprivacy build/macOpenVM.app/Contents/Resources/
cp "$binary_directory/macopenvm" build/bin/macopenvm
worker_staging=$(mktemp "$PWD/build/macOpenVM.app/Contents/MacOS/.macopenvm-worker.XXXXXX")
cp "$binary_directory/macopenvm" "$worker_staging"
chmod 700 "$worker_staging"
codesign --force --sign - --identifier local.macOpenVM.worker --entitlements packaging/virtualization.entitlements "$worker_staging"
chmod 500 "$worker_staging"
mv -f "$worker_staging" build/macOpenVM.app/Contents/MacOS/macopenvm-worker
codesign --verify --strict -R '=identifier "local.macOpenVM.worker"' build/macOpenVM.app/Contents/MacOS/macopenvm-worker
python3 scripts/build_manifest.py worker-descriptor --worker build/macOpenVM.app/Contents/MacOS/macopenvm-worker --descriptor build/macOpenVM.app/Contents/Resources/macopenvm-worker.json --identifier local.macOpenVM.worker
cat > build/macOpenVM.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>macOpenVM</string>
<key>CFBundleDisplayName</key><string>macOpenVM</string>
<key>CFBundleIdentifier</key><string>local.macOpenVM</string>
<key>CFBundleExecutable</key><string>macOpenVM</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --entitlements packaging/virtualization.entitlements build/bin/macopenvm
codesign --force --sign - --entitlements packaging/virtualization.entitlements build/macOpenVM.app
codesign --verify --strict build/bin/macopenvm
codesign --verify --strict build/macOpenVM.app
python3 scripts/build_manifest.py record --configuration "$configuration" --snapshot "$build_snapshot"
echo 'Built local development app and CLI. Ad hoc signed; not notarized.'
