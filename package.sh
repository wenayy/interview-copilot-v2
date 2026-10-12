#!/bin/bash
# Build a universal (Apple Silicon + Intel) InterviewCopilot.app and zip it for
# a GitHub Release as dist/InterviewCopilot-macOS.zip — the file the README's
# download link points to. Upload it with:
#   gh release create vX.Y.Z dist/InterviewCopilot-macOS.zip
set -euo pipefail

UNIVERSAL=1 ./build_app.sh release

mkdir -p dist
rm -f dist/InterviewCopilot-macOS.zip
ditto -c -k --sequesterRsrc --keepParent InterviewCopilot.app dist/InterviewCopilot-macOS.zip

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
echo "✅ dist/InterviewCopilot-macOS.zip (v$VERSION, $(lipo -archs InterviewCopilot.app/Contents/MacOS/InterviewCopilot))"
