import copy
import json
import tempfile
import shutil
import unittest
from pathlib import Path

from build_bank_catalog import parse_fdic, record
from bank_registry_formats import merge_regulator_records, parse_nic, parse_ncua, parse_cbr_foreign
from datetime import date
import csv
import io
from zipfile import ZipFile
from verify_financial_catalog import inspect, verify_bundled_catalog


class FinancialCatalogTests(unittest.TestCase):
    def test_fdic_truncation_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'truncated'):
            parse_fdic(json.dumps({'meta': {'total': 4223}, 'data': []}))

    def test_current_catalog_guarantees_top_twenty_without_claiming_full_coverage(self):
        path = Path(__file__).resolve().parent.parent / 'Sources/BudgetCore/Resources/banks.json'
        report = inspect(path)
        self.assertGreater(report['records'], 10000)
        self.assertGreaterEqual(report['verifiedRequiredLogos'], 60)
        self.assertEqual(report['missingRequiredLogos'], [])
        self.assertEqual(report['status'], 'ready', report['issues'])
        self.assertFalse(report['namesComplete'])
        self.assertTrue(report['coverageNotes'])

    def test_installed_catalog_requires_exact_reviewed_metadata_and_prepared_logos(self):
        source = Path(__file__).resolve().parent.parent / 'Sources/BudgetCore/Resources'
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'Example.app'
            resources = app / 'Contents/Resources/BudgetCore.bundle'
            resources.mkdir(parents=True)
            for name in ('banks.json', 'bank-brands.json', 'bank-markets.json', 'bank-rankings.json'):
                shutil.copy2(source / name, resources / name)
            for logo in (source / 'BankLogos').glob('*.png'):
                shutil.copy2(logo, resources / logo.name)
            # Every reviewed resource must ship, including retained optional marks.
            report = verify_bundled_catalog(app, source, require_complete=False)
            self.assertEqual(report['verifiedLogos'], inspect(source / 'banks.json')['verifiedLogos'])
            self.assertEqual(verify_bundled_catalog(app, source)['status'], 'ready')
            logo = resources / 'ru-sber.png'
            original = logo.read_bytes()
            logo.unlink()
            with self.assertRaisesRegex(ValueError, 'missing or altered'):
                verify_bundled_catalog(app, source, require_complete=False)
            logo.write_bytes(original + b'changed')
            with self.assertRaisesRegex(ValueError, 'missing or altered'):
                verify_bundled_catalog(app, source, require_complete=False)
            logo.write_bytes(original)
            markets = resources / 'bank-markets.json'
            markets.write_bytes(markets.read_bytes() + b'\n')
            with self.assertRaisesRegex(ValueError, 'differs'):
                verify_bundled_catalog(app, source, require_complete=False)
            markets.unlink()
            with self.assertRaisesRegex(ValueError, 'differs'):
                verify_bundled_catalog(app, source, require_complete=False)

    def test_regulator_identity_merge_preserves_current_ids_and_historical_aliases(self):
        current = record('us-nic-11', 'Example Community Credit Union', 'US', 'creditUnion', {'RSSD':'11', 'NCUA':'101'})
        current['registryEffectiveOn'] = '2026-10-06'
        older = record('us-ncua-100', 'Example Community', 'US', 'creditUnion', {'RSSD':'11', 'NCUA':'100'})
        older['registryEffectiveOn'] = '2026-06-30'
        result = merge_regulator_records([current,older])
        self.assertEqual(len(result),1)
        self.assertEqual(result[0]['regulatorIDs']['NCUA'],'101')
        self.assertEqual(result[0]['historicalRegulatorIDs'],[{'regulator':'NCUA','value':'100','effectiveOn':'2026-06-30'}])
        self.assertIn('us-ncua-100',result[0]['sourceIDs'])
        conflict = record('other', 'Other', 'US', 'creditUnion', {'RSSD':'11','NCUA':'102'})
        conflict['registryEffectiveOn']='2026-10-06'
        with self.assertRaisesRegex(ValueError,'Conflicting'):
            merge_regulator_records([current,conflict])

    def test_nic_excludes_holding_companies_and_closed_foreign_offices(self):
        columns=['#ID_RSSD','ENTITY_TYPE','NM_LGL','DOMESTIC_IND','D_DT_EXIST_TERM','D_DT_END','ID_RSSD_HD_OFF']
        text=io.StringIO(); writer=csv.writer(text); writer.writerow(columns)
        writer.writerow(['1','UFB','London bank branch','Y','12/31/9999','12/31/9999','99'])
        writer.writerow(['2','USB','Closed office','Y','01/01/2026','01/01/2026','99'])
        writer.writerow(['3','BHC','Holding company','Y','12/31/9999','12/31/9999','0'])
        archive=io.BytesIO()
        with ZipFile(archive,'w') as zipped:zipped.writestr('CSV_ATTRIBUTES_BRANCHES.CSV',text.getvalue())
        rows,_=parse_nic(archive.getvalue(),record,branches=True,as_of=date(2026,10,6),parent_names={'99':'Example Bank'})
        self.assertEqual([row['id'] for row in rows],['us-nic-1'])
        self.assertEqual(rows[0]['name'],'Example Bank · London bank branch')

    def test_removed_source_member_cannot_be_hidden_by_coverage_flags(self):
        path=Path(__file__).resolve().parent.parent/'Sources/BudgetCore/Resources/banks.json'
        catalog=json.loads(path.read_text());catalog['banks']=[bank for bank in catalog['banks'] if bank['country']!='GB']
        with tempfile.TemporaryDirectory() as directory:
            fixture=Path(directory)/'banks.json';fixture.write_text(json.dumps(catalog))
            self.assertTrue(any('Source members' in issue for issue in inspect(fixture, allow_legacy=True)['issues']))

    def test_completeness_flags_cannot_hide_missing_resources(self):
        path = Path(__file__).resolve().parent.parent / 'Sources/BudgetCore/Resources/banks.json'
        catalog = copy.deepcopy(json.loads(path.read_text()))
        catalog['manifest']['namesComplete'] = True
        catalog['manifest']['logosComplete'] = True
        catalog['manifest']['notes'] = []
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / 'banks.json'
            fixture.write_text(json.dumps(catalog))
            report = inspect(fixture, allow_legacy=True)
            self.assertEqual(report['status'], 'incomplete')
            self.assertGreater(report['missingActiveLogos'], 0)

    def test_top_twenty_scope_allows_other_banks_without_logos(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.logo_fixture(directory)
            report = inspect(fixture, allow_legacy=True)
            self.assertEqual(report['status'], 'ready', report['issues'])
            self.assertEqual(report['verifiedRequiredLogos'], 60)
            self.assertGreater(report['missingActiveLogos'], 10000)

    def logo_fixture(self, directory):
        source = Path(__file__).resolve().parent.parent / 'Sources/BudgetCore/Resources'
        root = Path(directory)
        shutil.copytree(source / 'BankLogos', root / 'BankLogos')
        catalog = json.loads((source / 'banks.json').read_text())
        brands = json.loads((source / 'bank-brands.json').read_text())
        brands['scope'] = 'top20-per-market'
        brands['targets'] = [target for target in brands['targets'] if target['country'] in ('RU', 'US', 'GB')]
        catalog['manifest']['namesComplete'] = True
        catalog['manifest']['logosComplete'] = True
        catalog['manifest']['coveredScopes'] += ['us_state_banks', 'us_state_credit_unions']
        catalog['manifest']['notes'] = []
        catalog['manifest']['nameScope'] = 'top20-per-market'
        catalog['manifest']['logoScope'] = 'top20-per-market'
        for target in brands['targets']: target.pop('usageReview', None)
        (root / 'bank-brands.json').write_text(json.dumps(brands))
        fixture = root / 'banks.json'; fixture.write_text(json.dumps(catalog))
        return fixture

    def test_one_missing_required_logo_blocks_release_despite_complete_flags(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.logo_fixture(directory)
            (fixture.parent / 'BankLogos/ru-sber.png').unlink()
            report = inspect(fixture, allow_legacy=True)
            self.assertEqual(report['missingRequiredLogos'], ['ru-cbr-1481'])
            self.assertEqual(report['status'], 'incomplete')

    def test_logo_target_cannot_be_replaced_with_wrong_market_or_duplicate(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.logo_fixture(directory)
            path = fixture.parent / 'bank-brands.json'; brands = json.loads(path.read_text())
            brands['targets'][0]['bankID'] = brands['targets'][10]['bankID']
            path.write_text(json.dumps(brands))
            self.assertTrue(any('sixty distinct' in issue for issue in inspect(fixture, allow_legacy=True)['issues']))
            brands['targets'][0]['bankID'] = 'ru-cbr-1481'; brands['targets'][0]['country'] = 'US'
            path.write_text(json.dumps(brands))
            self.assertEqual(inspect(fixture, allow_legacy=True)['status'], 'incomplete')

    def test_twentieth_bank_in_each_market_is_mandatory(self):
        for market in ('RU', 'US', 'GB'):
            with self.subTest(market=market), tempfile.TemporaryDirectory() as directory:
                fixture = self.logo_fixture(directory)
                brands = json.loads((fixture.parent / 'bank-brands.json').read_text())
                target = next(item for item in brands['targets'] if item['country'] == market and item['rank'] == 20)
                (fixture.parent / 'BankLogos' / target['logoResource']).unlink()
                report = inspect(fixture, allow_legacy=True)
                self.assertEqual(report['status'], 'incomplete')
                self.assertIn(target['bankID'], report['missingRequiredLogos'])

    def test_old_ten_bank_scope_cannot_pass_new_release_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.logo_fixture(directory)
            catalog = json.loads(fixture.read_text())
            catalog['manifest']['nameScope'] = 'top10-per-market'
            fixture.write_text(json.dumps(catalog))
            self.assertTrue(any('coverage scope' in issue for issue in inspect(fixture, allow_legacy=True)['issues']))

    def test_logo_usage_review_is_not_waived_by_a_complete_flag(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.logo_fixture(directory)
            path = fixture.parent / 'bank-brands.json'; brands = json.loads(path.read_text())
            brands['targets'][0]['usageReview'] = 'pending'; path.write_text(json.dumps(brands))
            self.assertTrue(any('usage review pending' in issue for issue in inspect(fixture, allow_legacy=True)['issues']))


if __name__ == '__main__':
    unittest.main()
