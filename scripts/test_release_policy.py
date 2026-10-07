"""Exercise packaging refusal before archives or signatures when release policy is not met."""
import json
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from release_entitlements import validate_entitlements


class ReleasePolicyTests(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory(prefix='BeeSaveReleasePolicy-')
        self.root = Path(self.workspace.name)
        source = Path(__file__).resolve().parent.parent
        (self.root / 'scripts').mkdir()
        for name in ('package_release.py', 'verify_financial_catalog.py', 'release_entitlements.py'):
            shutil.copyfile(source / 'scripts' / name, self.root / 'scripts' / name)
        expected = plistlib.loads((source / 'App/Info.plist').read_bytes())
        (self.root / 'App').mkdir()
        (self.root / 'App/Info.plist').write_bytes(plistlib.dumps(expected))
        self.app = self.root / 'Candidate.app'
        (self.app / 'Contents').mkdir(parents=True)
        info = dict(expected, CFBundleShortVersionString='1.3.0', CFBundleVersion='7', CFBundleIdentifier='com.mubudget.app')
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        resources = self.root / 'Sources/BudgetCore/Resources'
        resources.mkdir(parents=True)
        (resources / 'banks.json').write_text(json.dumps({'manifest': {'sources': [], 'namesComplete': False, 'logosComplete': False}, 'banks': []}))
        self.output = self.root / 'Output'

    def tearDown(self):
        self.workspace.cleanup()

    def refused(self, options, message):
        result = subprocess.run(['python3', str(self.root / 'scripts/package_release.py'), str(self.app),
            str(self.root / 'UnusedTools'), '--output', str(self.output), *options], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(message, result.stdout + result.stderr)
        self.assertFalse(self.output.exists(), 'Refused release must not produce archives')

    def testIncompleteCatalogCannotProduceStableArchives(self):
        self.refused([], 'incomplete')

    def testCandidateRequiresExplicitCandidateTag(self):
        self.refused(['--pre-release'], 'explicit candidate tag')

    def testCandidateTagCannotBePackagedAsStable(self):
        self.refused(['--tag', 'v1.3.0-rc.1'], 'require --pre-release')


class EntitlementPolicyTests(unittest.TestCase):
    def setUp(self):
        self.template = plistlib.loads((Path(__file__).resolve().parent.parent / 'App/BeeSave.entitlements').read_bytes())
        self.expected = plistlib.loads(plistlib.dumps(self.template).replace(
            b'$(PRODUCT_BUNDLE_IDENTIFIER)', b'com.mubudget.app'))

    def testExpandedProductionPolicyAccepted(self):
        validate_entitlements(self.expected, self.template, 'com.mubudget.app')

    def testUnexpandedSparkleServicesRejected(self):
        with self.assertRaisesRegex(ValueError, 'expanded release policy'):
            validate_entitlements(self.template, self.template, 'com.mubudget.app')

    def testMissingSandboxAndExtraAccessRejected(self):
        for key, value in [('com.apple.security.app-sandbox', False),
                           ('com.apple.security.files.downloads.read-write', True)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_entitlements(dict(self.expected, **{key: value}), self.template, 'com.mubudget.app')


if __name__ == '__main__':
    unittest.main()
