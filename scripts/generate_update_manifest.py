"""Create the GitHub update contract from the built app and its exact ZIP."""
import hashlib
import json
import plistlib
import re
import sys
from pathlib import Path

app, archive, output = map(Path, sys.argv[1:])
with (app / "Contents/Info.plist").open("rb") as source:
    info = plistlib.load(source)
version = info["CFBundleShortVersionString"]
build = int(info["CFBundleVersion"])
minimum = info["LSMinimumSystemVersion"]
if (not re.fullmatch(r"[0-9]{1,9}(\.[0-9]{1,9}){0,2}", version)
        or not re.fullmatch(r"[0-9]{1,9}(\.[0-9]{1,9}){0,2}", minimum)
        or build <= 0 or info["CFBundleIdentifier"] != "com.mubudget.app"):
    raise SystemExit("Invalid release version, build, platform, or bundle identifier")
digest = hashlib.sha256()
with archive.open("rb") as source:
    for chunk in iter(lambda: source.read(1024 * 1024), b""):
        digest.update(chunk)
manifest = {
    "schema_version": 1, "version": version, "build": build,
    "minimum_macos": minimum, "architecture": "arm64", "repository": "BeeSave/BeeSave",
    "tag": "v" + version,
    "asset_url": f"https://github.com/BeeSave/BeeSave/releases/download/v{version}/BeeSave-macos-arm64.zip",
    "sha256": digest.hexdigest(),
}
output.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
