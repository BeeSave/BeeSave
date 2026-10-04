#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
derived="${BEESAVE_BUILD_DIR:-/private/tmp/BeeSaveRelease}"
cd "$project_dir"
xcodebuild -quiet -project BeeSave.xcodeproj -scheme BeeSave \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived" build
app="$derived/Build/Products/Release/BeeSave.app"
codesign --verify --deep --strict "$app"
mkdir -p "$project_dir/Dist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
archive="$project_dir/Dist/BeeSave-${version}-arm64.zip"
ditto -c -k --norsrc --keepParent "$app" "$archive"
(cd "$project_dir/Dist" && shasum -a 256 "${archive:t}" > "${archive:t}.sha256")
print "Архив: $archive"
