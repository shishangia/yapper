#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA="${DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Yapper}"
PACKAGES="${PACKAGES:-$DERIVED_DATA/SourcePackages}"
args=(-project "$ROOT/Yapper.xcodeproj" -scheme Yapper -configuration "$CONFIGURATION"
      -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA"
      -clonedSourcePackagesDirPath "$PACKAGES" -onlyUsePackageVersionsFromResolvedFile)
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    args+=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$SIGN_IDENTITY" "DEVELOPMENT_TEAM=${APPLE_TEAM_ID:-}")
else
    args+=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
fi
xcodebuild "${args[@]}" build
