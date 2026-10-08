import copy
import json
from pathlib import Path
import tempfile
import unittest
from world_bank_catalog import SCOPE, COUNTRIES, ECONOMY_COUNTRIES, LOGO_COUNTRIES, check_rankings, apply_rankings, inspect_world


class WorldBankCatalogTests(unittest.TestCase):
    def setUp(self):
        self.markets = json.loads((Path(__file__).resolve().parents[1] / 'Sources/BudgetCore/Resources/bank-markets.json').read_text())
        self.rankings = dict(version=1, scope=SCOPE, countries={c: dict(
            url='https://example.test/' + c, effectiveOn='2025-12-31', retrievedOn='2026-10-08',
            sourceSHA256='a' * 64, basis='Fictional test bank balance sheets', assetUnit='test units', banks=[
                dict(id=c + '-' + str(i), name='Example Bank ' + str(i), rank=i, assets=str(100 - i)) for i in range(1, 21)
            ]) for c in COUNTRIES})
        self.rankings['economySource'] = dict(dataset='IMF.RES:WEO(9.0.0)', release='April 2026',
            indicator='NGDPD', year=2025, unit='Billions of current US dollars',
            url='https://example.test/fictional-gdp.xlsx', sha256='c' * 64,
            publicationDate='2026-04-14', retrievedOn='2026-10-08', methodology='Fictional structural test data',
            values=[dict(country=country, rank=rank, gdpBillionsUSD=200-rank)
                    for rank, country in enumerate(ECONOMY_COUNTRIES, 1)])

    def test_full_scope_and_proven_smaller_system(self):
        self.assertEqual(check_rankings(self.rankings, self.markets), [])
        cd = self.rankings['countries']['CD']; cd['banks'] = cd['banks'][:3]
        self.assertTrue(any('smaller system' in issue for issue in check_rankings(self.rankings, self.markets)))
        cd['smallSystem'] = dict(activeBanks=3, url='https://example.test/regulator', effectiveOn='2025-12-31', sourceSHA256='b' * 64)
        self.assertEqual(check_rankings(self.rankings, self.markets), [])
        cd['smallSystem']['activeBanks'] = 4
        self.assertTrue(check_rankings(self.rankings, self.markets))
        cd['smallSystem']['activeBanks'] = 3
        cd['smallSystem']['effectiveOn'] = '2027-01-01'
        self.assertTrue(check_rankings(self.rankings, self.markets))
        cd['smallSystem']['effectiveOn'] = '2025-12-31'
        cd['banks'] = cd['banks'][:1]
        cd['smallSystem']['activeBanks'] = True
        self.assertTrue(check_rankings(self.rankings, self.markets))

    def test_missing_country_is_not_waived_by_complete_flags_or_smaller_system(self):
        del self.rankings['countries']['DE']
        self.rankings['complete'] = True
        self.assertIn('World ranking unavailable: DE.', check_rankings(self.rankings, self.markets))
        self.assertEqual(check_rankings(self.rankings, self.markets, require_all=False), [])

    def test_duplicate_identity_and_inconsistent_ranking_are_rejected(self):
        for mutation in ('identity', 'rank', 'asset', 'date', 'source', 'unit'):
            with self.subTest(mutation=mutation):
                data = copy.deepcopy(self.rankings); ca = data['countries']['CA']
                if mutation == 'identity': ca['banks'][0]['id'] = data['countries']['US']['banks'][0]['id']
                if mutation == 'rank': ca['banks'][0]['rank'] = True
                if mutation == 'asset': ca['banks'][19]['assets'] = '1000'
                if mutation == 'date': ca['effectiveOn'] = '2027-01-01'
                if mutation == 'source': ca['sourceSHA256'] = ''
                if mutation == 'unit': ca['assetUnit'] = ''
                self.assertTrue(check_rankings(data, self.markets))

    def test_geography_currency_and_logo_changes_are_rejected(self):
        for key, value in [('currency', 'USD'), ('areaRank', 30), ('economyRank', 20), ('requiresLogos', False)]:
            markets = copy.deepcopy(self.markets); markets[1][key] = value
            self.assertTrue(check_rankings(self.rankings, markets))

    def test_approximate_order_requires_current_identity_proof_without_invented_assets(self):
        data = copy.deepcopy(self.rankings)
        de = data['countries']['DE']; de['ordering'] = 'approximate-size'
        for row in de['banks']:
            del row['assets']
            row.update(active=True, activeVerifiedOn='2026-10-08',
                       activeSource=dict(url='https://example.test/current-register', sha256='d' * 64))
        self.assertEqual(check_rankings(data, self.markets), [])
        for field, value in [('activeVerifiedOn', '2024-01-01'), ('activeVerifiedOn', '2027-01-01'),
                             ('activeSource', dict(url='https://example.test/register', sha256='')),
                             ('active', False)]:
            changed = copy.deepcopy(data)
            changed['countries']['DE']['banks'][0][field] = value
            self.assertTrue(check_rankings(changed, self.markets), field)
        del de['ordering']
        self.assertTrue(any('Assets or published' in issue for issue in check_rankings(data, self.markets)))

    def test_optional_new_logos_never_waive_economic_country_coverage(self):
        self.assertNotIn('DE', LOGO_COUNTRIES)
        del self.rankings['countries']['DE']
        self.assertIn('World ranking unavailable: DE.', check_rankings(self.rankings, self.markets))
        self.rankings['countries']['JP']['reviewPending'] = 'Current names not verified'
        with self.assertRaisesRegex(ValueError, 'review pending: JP'):
            apply_rankings(dict(manifest={}, banks=[]), self.rankings, self.markets)

    def catalog(self):
        banks = [dict(id=row['id'], name=row['name'], legalName=row['name'], country=c, active=True)
                 for c, dataset in self.rankings['countries'].items() for row in dataset['banks']]
        banks += [dict(id='manual-extra', name='Additional', country='CA', active=True)]
        return apply_rankings(dict(manifest=dict(notes=[], logosComplete=True), banks=banks), self.rankings, self.markets)

    def test_import_preserves_additional_banks_and_reconciles_exact_world_scope(self):
        catalog = self.catalog()
        self.assertEqual(len(catalog['banks']), len(COUNTRIES) * 20 + 1)
        self.assertNotIn('assetRank', catalog['banks'][-1])
        self.assertEqual(catalog['manifest']['nameScope'], SCOPE)
        self.assertFalse(catalog['manifest']['logosComplete'])
        targets = [dict(bankID=row['id'], country=c, rank=row['rank']) for c, data in self.rankings['countries'].items()
                   if c in LOGO_COUNTRIES for row in data['banks']]
        brands = dict(scope=SCOPE, targets=targets)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'banks.json'
            (path.parent / 'bank-rankings.json').write_text(json.dumps(self.rankings))
            (path.parent / 'bank-markets.json').write_text(json.dumps(self.markets))
            issues, required = inspect_world(path, catalog, brands)
            self.assertEqual(issues, [])
            self.assertEqual(len(required), 200)
            for field in ('name', 'legalName'):
                with self.subTest(field=field):
                    changed = copy.deepcopy(catalog)
                    bank = next(b for b in changed['banks'] if b['id'] == 'CA-1')
                    bank[field] = 'Unreconciled name'
                    self.assertIn('Ranked bank name is not reconciled: CA-1.', inspect_world(path, changed, brands)[0])
            brands['targets'].pop()
            self.assertTrue(inspect_world(path, catalog, brands)[0])

    def test_retained_optional_market_is_not_mandatory_but_present_data_is_validated(self):
        del self.rankings['countries']['SD']
        self.rankings['countries']['CD']['reviewPending'] = 'Historical slice retained; current licence count unresolved'
        self.assertEqual(check_rankings(self.rankings, self.markets), [])
        self.rankings['countries']['CD']['banks'][0]['assets'] = '-1'
        self.assertTrue(any('invalid in CD' in issue for issue in check_rankings(self.rankings, self.markets)))

    def test_gdp_measure_year_source_and_order_cannot_be_substituted(self):
        for mutation in ('measure', 'year', 'digest', 'order', 'value'):
            with self.subTest(mutation=mutation):
                data = copy.deepcopy(self.rankings); source = data['economySource']
                if mutation == 'measure': source['indicator'] = 'PPPGDP'
                if mutation == 'year': source['year'] = 2026
                if mutation == 'digest': source['sha256'] = ''
                if mutation == 'order': source['values'][-1]['country'] = 'PL'
                if mutation == 'value': source['values'][-1]['gdpBillionsUSD'] = 300
                self.assertTrue(any('Economic scope source invalid' in issue for issue in check_rankings(data, self.markets)))

    def test_retained_logo_targets_are_allowed_only_for_matching_ranked_banks(self):
        catalog = self.catalog()
        targets = [dict(bankID=row['id'], country=c, rank=row['rank']) for c, data in self.rankings['countries'].items()
                   if c in LOGO_COUNTRIES for row in data['banks']]
        targets.append(dict(bankID='CD-1', country='CD', rank=1))
        brands = dict(scope=SCOPE, targets=targets)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'banks.json'
            (path.parent / 'bank-rankings.json').write_text(json.dumps(self.rankings))
            (path.parent / 'bank-markets.json').write_text(json.dumps(self.markets))
            issues, required = inspect_world(path, catalog, brands)
            self.assertEqual(issues, [])
            self.assertEqual(len(required), 200)
            targets[-1]['country'] = 'JP'
            self.assertTrue(inspect_world(path, catalog, brands)[0])

    def test_pending_review_cannot_pass_acceptance_and_inactive_identity_cannot_import(self):
        catalog = self.catalog()
        self.rankings['countries']['CA']['reviewPending'] = 'Licence verification'
        self.assertTrue(any('review pending' in issue for issue in check_rankings(self.rankings, self.markets)))
        before = copy.deepcopy(catalog)
        with self.assertRaisesRegex(ValueError, 'Economic ranking review pending: CA'):
            apply_rankings(catalog, self.rankings, self.markets)
        self.assertEqual(catalog, before, 'Rejected candidates must not clear existing ranks or mutate banks')
        del self.rankings['countries']['CA']['reviewPending']
        catalog['banks'][0]['active'] = False
        before = copy.deepcopy(catalog)
        with self.assertRaisesRegex(ValueError, 'status mismatch'):
            apply_rankings(catalog, self.rankings, self.markets)
        self.assertEqual(catalog, before)

    def test_late_import_failure_preserves_existing_ranks_and_discards_staged_banks(self):
        catalog = self.catalog()
        # An earlier market stages a new bank and changes an existing name.
        catalog['banks'] = [bank for bank in catalog['banks'] if bank['id'] != 'CA-1']
        self.rankings['countries']['CA']['banks'][1]['name'] = 'Updated Example Bank'
        # The last country fails after the earlier countries have been read.
        late = next(bank for bank in catalog['banks'] if bank['id'] == 'CH-20')
        late['country'] = 'CA'
        before = copy.deepcopy(catalog)
        with self.assertRaisesRegex(ValueError, 'country / status mismatch: CH-20'):
            apply_rankings(catalog, self.rankings, self.markets)
        self.assertEqual(catalog, before)
        late['country'] = 'CH'
        self.assertIs(apply_rankings(catalog, self.rankings, self.markets), catalog)
        self.assertTrue(any(bank['id'] == 'CA-1' for bank in catalog['banks']))

    def test_ranked_source_requires_active_boolean_for_existing_and_new_banks(self):
        catalog = self.catalog()
        for status in (False, 0, 1, None, 'false'):
            for existing in (True, False):
                with self.subTest(status=status, existing=existing):
                    data = copy.deepcopy(self.rankings)
                    row = data['countries']['CA']['banks'][0]
                    row['active'] = status
                    if not existing:
                        row['id'] = 'CA-new'
                    self.assertTrue(any('active with a boolean status' in issue
                                        for issue in check_rankings(data, self.markets)))
                    before = copy.deepcopy(catalog)
                    with self.assertRaisesRegex(ValueError, 'active with a boolean status'):
                        apply_rankings(catalog, data, self.markets)
                    self.assertEqual(catalog, before)
        # Omitted status retains the default; an explicit true value is valid.
        self.rankings['countries']['CA']['banks'][0]['active'] = True
        self.assertEqual(check_rankings(self.rankings, self.markets), [])
        self.assertIs(apply_rankings(catalog, self.rankings, self.markets), catalog)

    def test_rebuild_retains_bank_displaced_from_top_twenty(self):
        initial = self.catalog()
        ca = self.rankings['countries']['CA']
        retained = ca['banks'][0].copy()
        retained.pop('rank')
        ca['additionalBanks'] = [retained]
        ca['banks'][0] = dict(ca['banks'][0], id='CA-new', name='New Example Bank')
        # Rebuild from regulator input, without relying on a previous generated JSON.
        seed = dict(manifest=dict(notes=[]), banks=[b for b in initial['banks'] if b['country'] in ('RU', 'US', 'GB')])
        rebuilt = apply_rankings(seed, self.rankings, self.markets)
        old = next(b for b in rebuilt['banks'] if b['id'] == 'CA-1')
        self.assertTrue(old['active'])
        self.assertNotIn('assetRank', old)
        self.assertEqual(len([b for b in rebuilt['banks'] if b['country'] == 'CA' and b.get('assetRank')]), 20)
        ca['additionalBanks'][0]['rank'] = 21
        self.assertTrue(check_rankings(self.rankings, self.markets))
        ca['additionalBanks'][0].pop('rank')
        ca['additionalBanks'][0]['id'] = 'CA-new'
        self.assertTrue(check_rankings(self.rankings, self.markets))

    def test_existing_additional_bank_closure_updates_status_and_is_audited(self):
        catalog = self.catalog()
        self.rankings['countries']['CA']['additionalBanks'] = [
            dict(id='manual-extra', name='Closed Example Bank', legalName='Closed Example Bank Limited', active=False)]
        updated = apply_rankings(catalog, self.rankings, self.markets)
        retained = next(b for b in updated['banks'] if b['id'] == 'manual-extra')
        self.assertFalse(retained['active'])
        self.assertEqual(retained['legalName'], 'Closed Example Bank Limited')
        self.assertNotIn('assetRank', retained)
        targets = [dict(bankID=row['id'], country=c, rank=row['rank']) for c, data in self.rankings['countries'].items()
                   if c in LOGO_COUNTRIES for row in data['banks']]
        brands = dict(scope=SCOPE, targets=targets)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'banks.json'
            (path.parent / 'bank-rankings.json').write_text(json.dumps(self.rankings))
            (path.parent / 'bank-markets.json').write_text(json.dumps(self.markets))
            self.assertEqual(inspect_world(path, updated, brands)[0], [])
            retained['active'] = True
            self.assertIn('Additional bank country / status is not reconciled: manual-extra.', inspect_world(path, updated, brands)[0])
            retained['active'] = False
            retained['legalName'] = 'Stale name'
            self.assertIn('Additional bank name is not reconciled: manual-extra.', inspect_world(path, updated, brands)[0])


if __name__ == '__main__': unittest.main()
