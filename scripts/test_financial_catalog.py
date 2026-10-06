import copy
import json
import tempfile
import unittest
from pathlib import Path

from build_bank_catalog import parse_fdic
from verify_financial_catalog import inspect


class FinancialCatalogTests(unittest.TestCase):
    def test_fdic_truncation_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'truncated'):
            parse_fdic(json.dumps({'meta': {'total': 4223}, 'data': []}))

    def test_current_catalog_reports_actual_gaps(self):
        path = Path(__file__).resolve().parent.parent / 'Sources/BudgetCore/Resources/banks.json'
        report = inspect(path)
        self.assertEqual(report['records'], 6784)
        self.assertEqual(report['verifiedLogos'], 0)
        self.assertEqual(report['status'], 'incomplete')
        self.assertTrue(any('us_nic' in issue for issue in report['issues']))

    def test_completeness_flags_cannot_hide_missing_scopes_or_logos(self):
        path = Path(__file__).resolve().parent.parent / 'Sources/BudgetCore/Resources/banks.json'
        catalog = copy.deepcopy(json.loads(path.read_text()))
        catalog['manifest']['namesComplete'] = True
        catalog['manifest']['logosComplete'] = True
        catalog['manifest']['notes'] = []
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / 'banks.json'
            fixture.write_text(json.dumps(catalog))
            report = inspect(fixture)
            self.assertEqual(report['status'], 'incomplete')
            self.assertGreater(report['missingActiveLogos'], 0)


if __name__ == '__main__':
    unittest.main()
