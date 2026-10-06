"""Check the real package validator against validly signed and corrupted app variants."""
import argparse
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
parser.add_argument('identity')
args = parser.parse_args()
workspace = Path(tempfile.mkdtemp(prefix='BeeSavePackageTests-'))
runner = workspace / 'runner'
subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-framework', 'Foundation', '-framework', 'Security',
    '-I'+str(root / 'Vendor/Sparkle'), str(root / 'Tests/SparklePackageTests/main.m'), '-o', str(runner)], check=True)
entitlements = workspace / 'base.entitlements'
subprocess.run(['codesign', '-d', '--entitlements', str(entitlements), '--xml', str(args.app)], check=True)
rights = plistlib.loads(entitlements.read_bytes())
def test(name, mutate=None, sign=True, accepted=False, custom=None):
    app = workspace / name / 'BeeSave.app'
    app.parent.mkdir()
    subprocess.run(['ditto', str(args.app), str(app)], check=True)
    if mutate: mutate(app)
    if sign:
        policy = workspace / (name + '.entitlements')
        policy.write_bytes(plistlib.dumps(custom if custom is not None else rights))
        subprocess.run(['codesign', '--force', '--sign', args.identity, '--options', 'runtime', '--timestamp=none', '--entitlements', str(policy), str(app)], check=True)
    subprocess.run([str(runner), str(app), str(args.app), 'accept' if accepted else 'reject', name, 'reserved'], check=True)
    shutil.rmtree(app.parent)

def change(key, value):
    def mutate(app):
        path = app / 'Contents/Info.plist'
        info = plistlib.loads(path.read_bytes()); info[key] = value; path.write_bytes(plistlib.dumps(info))
    return mutate

test('same-certificate-package', accepted=True)
for key, value in [('CFBundleIdentifier', 'com.other.app'), ('CFBundleVersion', '7'),
    ('CFBundleShortVersionString', '1.3.0'), ('SUPublicEDKey', 'A'*44), ('SURequireSignedFeed', False),
    ('SUVerifyUpdateBeforeExtraction', False), ('SUSignedFeedFailureExpirationInterval', 3600)]:
    test('wrong-'+key, change(key, value))
test('entitlement-drift', custom=dict(rights, **{'com.apple.security.files.downloads.read-write': True}))
test('library-validation-disabled', custom=dict(rights, **{'com.apple.security.cs.disable-library-validation': True}))
def no_team(app):
    subprocess.run(['codesign', '--force', '--sign', '-', '--options', 'runtime', '--entitlements', str(entitlements), str(app)], check=True)
test('missing-team', no_team, sign=False)
def broken_nested(app):
    path = app / 'Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle'
    with path.open('r+b') as stream:
        stream.seek(512); byte = stream.read(1); stream.seek(512); stream.write(bytes([byte[0] ^ 1]))
test('corrupted-nested-code', broken_nested, sign=False)
def nested_no_team(app):
    framework = app / 'Contents/Frameworks/Sparkle.framework'
    subprocess.run(['codesign', '--force', '--sign', '-', '--options', 'runtime', str(framework)], check=True)
test('nested-team-missing', nested_no_team)
print('13 package checks passed; fixtures:', workspace)
