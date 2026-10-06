#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
derived="${BEESAVE_BUILD_DIR:-/private/tmp/BeeSaveRelease}"
cd "$project_dir"
xcodebuild -quiet -project BeeSave.xcodeproj -scheme BeeSave \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived" build
app="$derived/Build/Products/Release/BeeSave.app"
if [[ -z "${BEESAVE_SPARKLE_TOOLS:-}" ]]; then
  print "Укажите папку bin проверенного дистрибутива Sparkle 2.10.0 в BEESAVE_SPARKLE_TOOLS."
  exit 1
fi
python3 "$project_dir/scripts/package_release.py" "$app" "$BEESAVE_SPARKLE_TOOLS"
print "Вложения GitHub Release: DMG, подписанный appcast.xml, ZIP, SHA-256 обоих архивов и latest.json"
