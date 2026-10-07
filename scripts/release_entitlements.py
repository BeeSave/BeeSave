"""Require the built app's exact, expanded sandbox policy before distribution."""
import plistlib
import subprocess


def validate_entitlements(actual, template, bundle_identifier):
    expected = plistlib.loads(plistlib.dumps(template).replace(
        b'$(PRODUCT_BUNDLE_IDENTIFIER)', bundle_identifier.encode('utf-8')))
    if actual != expected:
        raise ValueError('Built app entitlements differ from the expanded release policy.')


def verify_app_entitlements(app, policy):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    result = subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', str(app)],
                            check=True, capture_output=True)
    actual = plistlib.loads(result.stdout)
    validate_entitlements(actual, plistlib.loads(policy.read_bytes()), info['CFBundleIdentifier'])
