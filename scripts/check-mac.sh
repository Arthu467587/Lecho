#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p work
printf '%s\n' 'Checking Xcode project and standalone caption logic...'
plutil -lint "L'écho.xcodeproj/project.pbxproj" Sources/Info.plist
xcrun swiftc -swift-version 5 Sources/TranscriptLedger.swift Sources/TranslationCore.swift Sources/ClassDocument.swift Sources/ClassroomPreferences.swift Sources/SemanticSegmentation.swift Sources/ClassContinuation.swift Tests/main.swift -o work/ledger-tests
work/ledger-tests
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  Sources/TranscriptLedger.swift Sources/TranslationCore.swift Sources/ClassDocument.swift \
  Sources/ClassroomPreferences.swift Sources/SemanticSegmentation.swift Sources/ClassContinuation.swift \
  Sources/DeepSeekTranslation.swift Tests/TranslationFinalization.swift -o work/finalization-tests
work/finalization-tests
if command -v node >/dev/null 2>&1; then
  node --test Tests/*.test.mjs
fi
printf '%s\n' 'Compiling unsigned iPad device build (this is NOT a runnable signed IPA)...'
xcodebuild -project "L'écho.xcodeproj" -scheme "L'écho" \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath work/DerivedData CODE_SIGNING_ALLOWED=NO build \
  > work/xcode-build.log 2>&1 || { tail -n 100 work/xcode-build.log; exit 1; }
printf '%s\n' 'PASS: unsigned iPad build. Sign and run on a physical iPad in Xcode to test Speech.'
