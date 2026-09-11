#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DERIVED_DATA="${DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Yapper}"
PACKAGES="${PACKAGES:-$DERIVED_DATA/SourcePackages}"
args=(-project "$ROOT/Yapper.xcodeproj" -scheme Yapper -configuration Debug
      -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA"
      -clonedSourcePackagesDirPath "$PACKAGES" -onlyUsePackageVersionsFromResolvedFile
      -parallel-testing-enabled NO -only-testing:YapperTests)
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    args+=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$SIGN_IDENTITY" "DEVELOPMENT_TEAM=${APPLE_TEAM_ID:-}")
else
    args+=(CODE_SIGNING_ALLOWED=NO)
fi
xcodebuild "${args[@]}" test
