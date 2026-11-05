#!/bin/bash
# Build a universal (Apple Silicon + Intel) finder.app and zip it for
# a GitHub Release as dist/InterviewCopilot-macOS.zip — the file the README's
# download link points to. Upload it with:
#   gh release create vX.Y.Z dist/InterviewCopilot-macOS.zip
set -euo pipefail

# Remove the old zip first so a failed build can't leave a stale one behind.
mkdir -p dist
rm -f dist/InterviewCopilot-macOS.zip

UNIVERSAL=1 KEEP_LOCAL=1 ./build_app.sh release

ditto -c -k --sequesterRsrc --keepParent finder.app dist/InterviewCopilot-macOS.zip

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
echo "✅ dist/InterviewCopilot-macOS.zip (v$VERSION, $(lipo -archs finder.app/Contents/MacOS/finder))"

# The local copy was only needed for the zip; remove it so Spotlight and
# Launchpad show just the installed /Applications/finder.app.
rm -rf finder.app
