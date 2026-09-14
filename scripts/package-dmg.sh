#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DERIVED_DATA="${DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Yapper}"
APP_PATH="${APP_PATH:-$DERIVED_DATA/Build/Products/Release/Yapper.app}"
PACKAGES="${PACKAGES:-$DERIVED_DATA/SourcePackages}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"
MODE="notarized"
if [[ "${1:-}" == "--local-test" && $# == 1 ]]; then
    MODE="local-test"
elif [[ $# != 0 ]]; then
    printf 'Usage: SIGN_IDENTITY="..." NOTARY_PROFILE="..." bash scripts/package-dmg.sh [--local-test]\n' >&2
    exit 1
fi
: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to an installed signing certificate.}"
if [[ "$MODE" == "notarized" ]]; then
    [[ "$SIGN_IDENTITY" == "Developer ID Application:"* ]] || {
        printf 'Public installers require a Developer ID Application certificate.\n' >&2
        exit 1
    }
    : "${NOTARY_PROFILE:?Set NOTARY_PROFILE to credentials already stored with notarytool.}"
fi

swift -e 'import CoreGraphics; if (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true { fputs("Unlock the Mac before packaging so Finder can save the installer layout.\n", stderr); exit(1) }'

codesign --verify --deep --strict "$APP_PATH"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")
[[ "$BUNDLE_ID" == "com.shishangia.yapper" ]] || { printf 'Use the Release Yapper.app, not a development app.\n' >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ && "$BUILD" =~ ^[0-9]+$ ]] || { printf 'Unexpected app version.\n' >&2; exit 1; }
ARCH=$(lipo -archs "$APP_PATH/Contents/MacOS/Yapper")
[[ "$ARCH" == "arm64" ]] || { printf 'This installer supports the Apple Silicon build only.\n' >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"
SUFFIX=""
[[ "$MODE" != "local-test" ]] || SUFFIX="-local-test"
DESTINATION="$OUTPUT_DIR/Yapper-$VERSION-$BUILD-arm64$SUFFIX.dmg"
[[ ! -e "$DESTINATION" && ! -e "$DESTINATION.sha256" ]] || { printf 'Output already exists; choose a new OUTPUT_DIR or build number.\n' >&2; exit 1; }
mkdir -p "$DERIVED_DATA/Packaging"
WORK=$(mktemp -d "$DERIVED_DATA/Packaging/package.XXXXXX")
MOUNT="/Volumes/Install Yapper"
[[ ! -e "$MOUNT" ]] || { printf 'Eject the existing Install Yapper volume before packaging.\n' >&2; exit 1; }
ATTACHED=0
cleanup() {
    local status=$?
    if [[ "$ATTACHED" == 1 ]] && ! hdiutil detach "$MOUNT"; then
        printf 'Could not eject packaging image. Preserved temporary files at %s\n' "$WORK" >&2
        exit 1
    fi
    if [[ "$status" != 0 ]]; then
        printf 'Packaging failed. Diagnostic files preserved at %s\n' "$WORK" >&2
    else
        rm -rf "$WORK"
    fi
    exit "$status"
}
trap cleanup EXIT
STAGE="$WORK/volume"
mkdir "$STAGE"
ditto "$APP_PATH" "$STAGE/Yapper.app"

python3 - "$ROOT" "$PACKAGES" "$STAGE/Yapper.app" "$MODE" "$STAGE" <<'PY'
import pathlib
import shutil
import sys

root, packages, app = map(pathlib.Path, sys.argv[1:4])
mode, stage = sys.argv[4], pathlib.Path(sys.argv[5])
licenses = app / "Contents/Resources/Licenses"
licenses.mkdir()
inputs = {
    "Yapper-MIT.txt": root / "LICENSE",
    "WhisperKit-MIT.txt": packages / "checkouts/WhisperKit/LICENSE",
    "WhisperKit-NOTICES.txt": packages / "checkouts/WhisperKit/NOTICES",
    "FluidAudio-Apache-2.0.txt": packages / "checkouts/FluidAudio/LICENSE",
    "KeyboardShortcuts-MIT.txt": packages / "checkouts/KeyboardShortcuts/license",
    "ArgumentParser-Apache-2.0.txt": packages / "checkouts/swift-argument-parser/LICENSE.txt",
}
for name, source in inputs.items():
    shutil.copyfile(source, licenses / name)
for source in sorted((packages / "checkouts/FluidAudio/ThirdPartyLicenses").iterdir()):
    if source.is_file():
        shutil.copyfile(source, licenses / ("FluidAudio-" + source.stem + ".txt"))

for path in app.rglob("*"):
    if path.is_symlink():
        if not path.resolve().is_relative_to(app.resolve()):
            raise SystemExit("External link inside app bundle: " + str(path.relative_to(app)))
    if path.suffix.lower() in {".wav", ".m4a", ".opus", ".mp3", ".p12", ".key", ".pem", ".safetensors", ".mlmodelc", ".log", ".dSYM".lower()}:
        raise SystemExit("Unexpected private or development artifact: " + str(path.relative_to(app)))
    if path.name in {".env", ".git", ".claude", ".trae", "TestAudio", "Recordings"}:
        raise SystemExit("Unexpected development directory: " + str(path.relative_to(app)))

instructions = """Install Yapper

1. Drag Yapper into the Applications folder beside it.
2. Eject this disk image, then open Yapper from Applications.
3. Follow the permission prompts and download a model in AI Models.

Requires macOS 14 or later and an Apple Silicon Mac (M1 or newer).
Model downloads need an internet connection. Transcription runs on your Mac.
Microphone access is needed for recording; Accessibility enables hotkeys and pasting.
This installer does not include recordings, personal settings, or model weights.

Source and support: https://github.com/shishangia/yapper
License notices are inside Yapper.app/Contents/Resources/Licenses.
"""
if mode == "local-test":
    instructions = "LOCAL PACKAGING TEST ONLY. Not notarized. Do not distribute.\n\n" + instructions
(stage / "Install Yapper.txt").write_text(instructions)
PY

python3 - "$STAGE/Yapper.app" "$SIGN_IDENTITY" "$MODE" <<'PY'
import pathlib
import subprocess
import sys

app, identity, mode = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
timestamp = "--timestamp" if mode == "notarized" else "--timestamp=none"
nested = [p for p in app.rglob("*") if not p.is_symlink() and p.suffix in {".bundle", ".framework", ".xpc", ".appex", ".dylib"}]
for path in sorted(nested, key=lambda p: len(p.parts), reverse=True):
    subprocess.run(["codesign", "--force", "--sign", identity, timestamp, str(path)], check=True)
PY
codesign --force --sign "$SIGN_IDENTITY" --options runtime \
    --entitlements "$ROOT/Yapper/Resources/Yapper.entitlements" \
    "$([[ "$MODE" == "notarized" ]] && printf '%s' '--timestamp' || printf '%s' '--timestamp=none')" "$STAGE/Yapper.app"
codesign --verify --deep --strict --verbose=2 "$STAGE/Yapper.app"

if [[ "$MODE" == "notarized" ]]; then
    ditto -c -k --keepParent "$STAGE/Yapper.app" "$WORK/Yapper.zip"
    xcrun notarytool submit "$WORK/Yapper.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$STAGE/Yapper.app"
    xcrun stapler validate "$STAGE/Yapper.app"
    spctl --assess --type execute --verbose=2 "$STAGE/Yapper.app"
fi

mkdir "$STAGE/.background"
swift "$ROOT/scripts/generate-dmg-background.swift" "$STAGE/.background/install.png"
hdiutil create -volname "Install Yapper" -srcfolder "$STAGE" -fs HFS+ -format UDRW "$WORK/layout.dmg"
hdiutil attach -readwrite -nobrowse -noautoopen "$WORK/layout.dmg"
ATTACHED=1
SetFile -a V "$MOUNT/Install Yapper.txt"
osascript - "$MOUNT" <<'APPLESCRIPT'
on run argv
    set volumeFolder to POSIX file (item 1 of argv) as alias
    tell application "Finder"
        make new alias file at volumeFolder to (POSIX file "/Applications" as alias) with properties {name:"Applications"}
    end tell
end run
APPLESCRIPT
swift - "$MOUNT/Applications" <<'SWIFT'
import AppKit
let icon = NSImage(contentsOfFile: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns")!
guard NSWorkspace.shared.setIcon(icon, forFile: CommandLine.arguments[1], options: []) else {
    fatalError("Could not set the Applications alias icon")
}
SWIFT
osascript - "$MOUNT" <<'APPLESCRIPT'
on run argv
    set mountPath to item 1 of argv
    set volumeFolder to POSIX file mountPath as alias
    set backgroundFile to POSIX file (mountPath & "/.background/install.png") as alias
    with timeout of 30 seconds
        tell application "Finder"
            set installerWindow to make new Finder window to volumeFolder
            set current view of installerWindow to icon view
            -- Initialize the folder's view record before applying custom options.
            close installerWindow
            set installerWindow to make new Finder window to volumeFolder
            delay 1
            set toolbar visible of installerWindow to false
            set statusbar visible of installerWindow to false
            set pathbar visible of installerWindow to false
            set bounds of installerWindow to {180, 180, 840, 622}
            set arrangement of icon view options of installerWindow to not arranged
            set icon size of icon view options of installerWindow to 112
            set text size of icon view options of installerWindow to 14
            set label position of icon view options of installerWindow to bottom
            set shows item info of icon view options of installerWindow to false
            set shows icon preview of icon view options of installerWindow to true
            set background picture of icon view options of installerWindow to backgroundFile
            set position of item "Yapper.app" of installerWindow to {180, 210}
            set position of item "Applications" of installerWindow to {480, 210}
            set extension hidden of item "Yapper.app" of installerWindow to true
            set position of item ".background" of installerWindow to {1100, 600}
            set position of item "Install Yapper.txt" of installerWindow to {1300, 600}
            if exists item ".fseventsd" of installerWindow then set position of item ".fseventsd" of installerWindow to {1500, 600}
            close installerWindow
            set installerWindow to make new Finder window to volumeFolder
            delay 1
            set bounds of installerWindow to {180, 180, 830, 612}
            delay 1
            set bounds of installerWindow to {180, 180, 840, 622}
            if icon size of icon view options of installerWindow is not 112 then error "Finder did not retain the installer icon size"
        end tell
    end timeout
end run
APPLESCRIPT
sync
hdiutil detach "$MOUNT"
ATTACHED=0
hdiutil attach -readonly -nobrowse -noautoopen "$WORK/layout.dmg"
ATTACHED=1
python3 - "$MOUNT/.DS_Store" <<'PY'
import pathlib
import plistlib
import struct
import sys
data = pathlib.Path(sys.argv[1]).read_bytes()
offset = 0
while True:
    offset = data.find(b"bplist00", offset)
    if offset < 0:
        break
    if offset >= 4:
        length = struct.unpack(">I", data[offset - 4:offset])[0]
        try:
            options = plistlib.loads(data[offset:offset + length])
        except (ValueError, TypeError, OverflowError):
            options = {}
        if isinstance(options, dict) and options.get("iconSize") == 112 and options.get("backgroundType") == 2 and options.get("arrangeBy") == "none":
            print("Verified saved installer background and icon layout")
            sys.exit(0)
    offset += 8
raise SystemExit("Finder did not retain the installer layout")
PY
hdiutil detach "$MOUNT"
ATTACHED=0
hdiutil convert "$WORK/layout.dmg" -format UDZO -o "$WORK/Yapper.dmg"
if [[ "$MODE" == "notarized" ]]; then
    codesign --sign "$SIGN_IDENTITY" --timestamp "$WORK/Yapper.dmg"
    xcrun notarytool submit "$WORK/Yapper.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$WORK/Yapper.dmg"
    xcrun stapler validate "$WORK/Yapper.dmg"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$WORK/Yapper.dmg"
fi
hdiutil verify "$WORK/Yapper.dmg"
mv "$WORK/Yapper.dmg" "$DESTINATION"
python3 - "$DESTINATION" <<'PY'
import hashlib
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
hasher = hashlib.sha256()
with path.open("rb") as source:
    for block in iter(lambda: source.read(1024 * 1024), b""):
        hasher.update(block)
digest = hasher.hexdigest()
path.with_suffix(path.suffix + ".sha256").write_text(digest + "  " + path.name + "\n")
print(str(path))
print("SHA256 " + digest)
PY
