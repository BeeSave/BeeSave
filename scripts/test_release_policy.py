"""Exercise packaging refusal before archives or signatures when release policy is not met."""
import json
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


class ReleasePolicyTests(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory(prefix='BeeSaveReleasePolicy-')
        self.root = Path(self.workspace.name)
        source = Path(__file__).resolve().parent.parent
        (self.root / 'scripts').mkdir()
        for name in ('package_release.py', 'verify_financial_catalog.py'):
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


if __name__ == '__main__':
    unittest.main()
