"""Create the GitHub update contract from the built app and its exact ZIP."""
import hashlib
import argparse
import json
import plistlib
import re
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
parser.add_argument('archive', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('--tag')
args = parser.parse_args()
app, archive, output = args.app, args.archive, args.output
with (app / "Contents/Info.plist").open("rb") as source:
    info = plistlib.load(source)
version = info["CFBundleShortVersionString"]
build = int(info["CFBundleVersion"])
minimum = info["LSMinimumSystemVersion"]
if (not re.fullmatch(r"[0-9]{1,9}(\.[0-9]{1,9}){0,2}", version)
        or not re.fullmatch(r"[0-9]{1,9}(\.[0-9]{1,9}){0,2}", minimum)
        or build <= 0 or info["CFBundleIdentifier"] != "com.mubudget.app"):
    raise SystemExit("Invalid release version, build, platform, or bundle identifier")
tag = args.tag or 'v' + version
if not re.fullmatch(r'v' + re.escape(version) + r'(?:-[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*)?', tag):
    raise SystemExit('Release tag must match the built app version')
digest = hashlib.sha256()
with archive.open("rb") as source:
    for chunk in iter(lambda: source.read(1024 * 1024), b""):
        digest.update(chunk)
manifest = {
    "schema_version": 1, "version": version, "build": build,
    "minimum_macos": minimum, "architecture": "arm64", "repository": "BeeSave/BeeSave",
    "tag": tag,
    "asset_url": f"https://github.com/BeeSave/BeeSave/releases/download/{tag}/BeeSave-macos-arm64.zip",
    "sha256": digest.hexdigest(),
}
output.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
