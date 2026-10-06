"""Check exact candidate hashes, Ed25519 signatures, ZIP and read-only DMG contents."""
import argparse
import hashlib
import json
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('directory', type=Path, nargs='?', default=root / 'Dist')
args = parser.parse_args()
workspace = Path(tempfile.mkdtemp(prefix='BeeSaveReleaseVerify-'))
runner = workspace / 'verify-ed25519'
subprocess.run(['xcrun', 'swiftc', str(root / 'scripts/verify_ed25519.swift'), '-o', str(runner)], check=True)
publicKey = plistlib.loads((root / 'App/Info.plist').read_bytes())['SUPublicEDKey']
feedFile = args.directory / 'appcast.xml'
feed = feedFile.read_bytes()
if len(feed) > 1024 * 1024: raise SystemExit('Feed size limit exceeded.')
marker = b'<!-- sparkle-signatures:\n'
position = feed.rfind(marker)
if position < 0: raise SystemExit('Missing signed feed.')
block = feed[position+len(marker):].decode('utf-8')
signature = re.search(r'^edSignature: (\S+)$', block, re.M)
length = re.search(r'^length: (\d+)$', block, re.M)
if not signature or not length or int(length[1]) != position: raise SystemExit('Invalid feed signature envelope.')
content = workspace / 'feed-content'
content.write_bytes(feed[:position])
def verify(file, signature, expected=True):
    result = subprocess.run([str(runner), str(file), publicKey, signature])
    if (result.returncode == 0) != expected: raise SystemExit('Unexpected signature verification result: '+str(file))
verify(content, signature[1])
items = ET.fromstring(feed).findall('./channel/item')
if len(items) != 1: raise SystemExit('Feed must pin a single release.')
item = items[0]
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
manifest = json.loads((args.directory / 'latest.json').read_text())
version = manifest['version']; build = str(manifest['build'])
if item.findtext(ns+'version') != build or item.findtext(ns+'shortVersionString') != version or item.findtext(ns+'minimumSystemVersion') != manifest['minimum_macos']:
    raise SystemExit('Feed and manifest versions differ.')
enclosure = item.find('enclosure')
if enclosure is None or enclosure.attrib['url'] != f'https://github.com/BeeSave/BeeSave/releases/download/v{version}/BeeSave-macos-arm64.dmg': raise SystemExit('Unexpected archive URL.')
dmg = args.directory / 'BeeSave-macos-arm64.dmg'
zipFile = args.directory / 'BeeSave-macos-arm64.zip'
for archive in [dmg, zipFile]:
    data = archive.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if len(data) > 200 * 1024 * 1024 or digest != (args.directory / (archive.name+'.sha256')).read_text().split()[0]: raise SystemExit('Archive hash or limit mismatch.')
    if archive == zipFile and manifest['sha256'] != digest: raise SystemExit('Legacy manifest hash mismatch.')
if int(enclosure.attrib['length']) != dmg.stat().st_size: raise SystemExit('DMG length mismatch.')
verify(dmg, enclosure.attrib[ns+'edSignature'])
corrupted = workspace / 'corrupt-feed'; corrupted.write_bytes(content.read_bytes().replace(b'1.2.0', b'1.2.9', 1))
verify(corrupted, signature[1], expected=False)
corruptedDmg = workspace / 'corrupt.dmg'
raw = bytearray(dmg.read_bytes()); raw[len(raw)//2] ^= 1; corruptedDmg.write_bytes(raw)
verify(corruptedDmg, enclosure.attrib[ns+'edSignature'], expected=False)
unpacked = workspace / 'ZIP'
subprocess.run(['ditto', '-x', '-k', str(zipFile), str(unpacked)], check=True)
mount = workspace / 'Mounted'
mount.mkdir()
subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(dmg)], check=True)
try:
    if not (mount / 'Applications').is_symlink() or (mount / 'Applications').readlink() != Path('/Applications'): raise SystemExit('DMG Applications link missing.')
    apps = [unpacked / 'BeeSave.app', mount / 'BeeSave.app']
    for app in apps:
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if info['CFBundleShortVersionString'] != version or info['CFBundleVersion'] != build or info['CFBundleIdentifier'] != 'com.mubudget.app': raise SystemExit('Packaged app metadata mismatch.')
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    def tree(app):
        return {str(path.relative_to(app)): ('link', str(path.readlink())) if path.is_symlink() else ('file', hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_mode & 0o777) for path in app.rglob('*') if path.is_file() or path.is_symlink()}
    if tree(apps[0]) != tree(apps[1]): raise SystemExit('DMG and ZIP apps differ.')
finally:
    subprocess.run(['hdiutil', 'detach', str(mount)], check=True)
print('Signatures, corruption rejection, hashes, metadata, executable permissions and DMG/ZIP app trees verified.')
print('Gatekeeper launch and installation are separate acceptance checks.')
