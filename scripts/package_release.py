"""Package the signed app as a read-only DMG, signed feed and compatible legacy ZIP."""
import argparse
import hashlib
import json
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path
from release_entitlements import verify_app_entitlements

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
parser.add_argument('tools', type=Path, help='Verified Sparkle distribution bin directory')
parser.add_argument('--output', type=Path, default=root / 'Dist')
parser.add_argument('--pre-release', action='store_true', help='Package an explicitly labelled testing candidate')
parser.add_argument('--tag', help='Release tag, e.g. v1.3.0-rc.1 for a pre-release')
args = parser.parse_args()
info = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
expected = plistlib.loads((root / 'App/Info.plist').read_bytes())
if any(info.get(key) != value for key, value in expected.items()):
    raise SystemExit('Built updater settings differ from the release policy.')
version = info['CFBundleShortVersionString']
tag = args.tag or 'v' + version
if not re.fullmatch(r'v' + re.escape(version) + r'(?:-[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*)?', tag):
    raise SystemExit('Release tag must match the built app version.')
if args.pre_release and tag == 'v' + version:
    raise SystemExit('A pre-release requires an explicit candidate tag, e.g. --tag v1.3.0-rc.1.')
if not args.pre_release and tag != 'v' + version:
    raise SystemExit('Candidate tags require --pre-release; stable releases use v<version>.')
catalog_report = None
if tuple(int(part) for part in version.split('.')) >= (1, 3, 0):
    command = ['python3', str(root / 'scripts/verify_financial_catalog.py')]
    if not args.pre_release:
        command.append('--require-complete')
    result = subprocess.run(command, capture_output=True, text=True)
    print(result.stdout)
    result.check_returncode()
    catalog_report = json.loads(result.stdout)
if info['CFBundleIdentifier'] != 'com.mubudget.app' or info.get('NSFaceIDUsageDescription'):
    raise SystemExit('Not a production password-only BeeSave package.')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(args.app)], check=True)
verify_app_entitlements(args.app, root / 'App/BeeSave.entitlements')
args.output.mkdir(parents=True, exist_ok=True)
workspace = Path(tempfile.mkdtemp(prefix='BeeSaveReleasePackage-'))
folder = workspace / 'Image'
folder.mkdir()
subprocess.run(['ditto', '--norsrc', str(args.app), str(folder / 'BeeSave.app')], check=True)
(folder / 'Applications').symlink_to('/Applications', target_is_directory=True)
feed = workspace / 'Feed'
feed.mkdir()
dmg = feed / 'BeeSave-macos-arm64.dmg'
subprocess.run(['hdiutil', 'create', '-srcfolder', str(folder), '-volname', 'BeeSave', '-format', 'UDZO', str(dmg)], check=True)
subprocess.run(['hdiutil', 'verify', str(dmg)], check=True)
subprocess.run([str(args.tools / 'generate_appcast'), '--account', 'BeeSave-releases-v1',
    '--download-url-prefix', f'https://github.com/BeeSave/BeeSave/releases/download/{tag}/',
    '--maximum-versions', '1', '--maximum-deltas', '0', str(feed)], check=True)
archive = workspace / 'BeeSave-macos-arm64.zip'
subprocess.run(['ditto', '-c', '-k', '--norsrc', '--keepParent', str(args.app), str(archive)], check=True)
subprocess.run(['python3', str(root / 'scripts/generate_update_manifest.py'), str(args.app), str(archive), str(workspace / 'latest.json'), '--tag', tag], check=True)
for file in [dmg, feed / 'appcast.xml', archive, workspace / 'latest.json']:
    if not file.is_file(): raise SystemExit('Missing release artifact: '+str(file))
    data = file.read_bytes()
    if file.suffix in {'.dmg', '.zip'} and len(data) > 200 * 1024 * 1024: raise SystemExit('Update archive exceeds 200 MiB.')
    destination = args.output / file.name
    destination.write_bytes(data)
    if file.suffix in {'.dmg', '.zip'}:
        (args.output / (file.name+'.sha256')).write_text(hashlib.sha256(data).hexdigest()+'  '+file.name+'\n')
if args.pre_release:
    (args.output / 'release-status.json').write_text(json.dumps({'status': 'pre-release', 'version': version,
        'build': info['CFBundleVersion'], 'tag': tag}, ensure_ascii=False, indent=2)+'\n')
print('Candidate artifacts:', args.output)
print('Packaging does not publish or mark system acceptance checks complete.')
