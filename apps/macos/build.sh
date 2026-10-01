#!/bin/bash
# Builds, tests and bundles the menu bar app with SwiftPM; Xcode is not needed.
#
#   ./build.sh test     unit tests
#   ./build.sh app      build/Pixelvisor.app (release)
#   ./build.sh run      build the app and open it
#
# BUNDLE_ID (default org.example.pixelvisor) and SIGN_IDENTITY (default "-", ad hoc) can be set
# in the environment. macOS ties Screen Recording permission to the signature: with ad hoc
# signing it has to be granted again after each build. Any stable code signing identity,
# even a self-signed one from Keychain Access, avoids that.
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID="${BUNDLE_ID:-org.example.pixelvisor}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
VERSION="${VERSION:-0.1.0}"
APP=build/Pixelvisor.app

# Command Line Tools without Xcode: some installs carry stale PackageDescription
# interfaces (manifests fail to link), and `swift test` does not find Swift Testing.
test_flags=()
CLT=/Library/Developer/CommandLineTools
if [[ "$(xcode-select -p)" == "$CLT" ]]; then
    manifest_api="$CLT/usr/lib/swift/pm/ManifestAPI"
    if [[ -n "$(find "$manifest_api" -name '*.private.swiftinterface' ! -newer "$manifest_api/libPackageDescription.dylib" 2>/dev/null)" ]]; then
        if [[ ! -d .build/pm ]]; then
            mkdir -p .build
            cp -R "$CLT/usr/lib/swift/pm" .build/pm
            find .build/pm -name '*.private.swiftinterface' -delete
        fi
        export SWIFTPM_CUSTOM_LIBS_DIR="$PWD/.build/pm"
    fi
    dev="$CLT/Library/Developer"
    test_flags=(-Xswiftc -F -Xswiftc "$dev/Frameworks" -Xlinker -rpath -Xlinker "$dev/Frameworks" -Xlinker -rpath -Xlinker "$dev/usr/lib")
fi

bundle() {
    swift build -c release --product Pixelvisor
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS"
    cp "$(swift build -c release --show-bin-path)/Pixelvisor" "$APP/Contents/MacOS/Pixelvisor"
    sed -e "s/\$(BUNDLE_ID)/$BUNDLE_ID/" -e "s/\$(VERSION)/$VERSION/" Info.plist > "$APP/Contents/Info.plist"
    codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP"
    echo "built $APP ($BUNDLE_ID, signed with '$SIGN_IDENTITY')"
}

case "${1:-app}" in
    # The +"..." form keeps bash 3.2 (macOS /bin/bash) from failing on an empty array under set -u.
    test) swift test ${test_flags[@]+"${test_flags[@]}"} ;;
    app) bundle ;;
    run)
        bundle
        pkill -x Pixelvisor || true
        open "$APP"
        ;;
    *) echo "usage: $0 test|app|run" >&2; exit 2 ;;
esac
