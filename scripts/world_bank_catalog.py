"""Offline ranking import and release coverage checks for the world bank catalogue."""
from copy import deepcopy
from datetime import date
from decimal import Decimal, InvalidOperation
import json
from pathlib import Path

SCOPE = 'top20-economies-plus-retained'
RETAINED_COUNTRIES = 'RU CA US CN BR AU IN AR KZ DZ CD SA MX ID SD LY IR MN PE TD NE AO ML ZA CO ET BO MR EG TZ GB'.split()
ECONOMY_COUNTRIES = 'US CN DE JP GB IN FR RU IT CA BR ES KR AU MX TR ID NL SA CH'.split()
COUNTRIES = RETAINED_COUNTRIES + [country for country in ECONOMY_COUNTRIES if country not in RETAINED_COUNTRIES]
LOGO_COUNTRIES = set('US CN GB IN RU CA BR AU MX TR'.split())
LEGACY = {'RU', 'US', 'GB'}
CURRENCIES = dict(zip(RETAINED_COUNTRIES, 'RUB CAD USD CNY BRL AUD INR ARS KZT DZD CDF SAR MXN IDR SDG LYD IRR MNT PEN XAF XOF AOA XOF ZAR COP ETB BOB MRU EGP TZS GBP'.split()))
CURRENCIES.update(DE='EUR', JP='JPY', FR='EUR', IT='EUR', ES='EUR', KR='KRW', TR='TRY', NL='EUR', CH='CHF')


def https(value):
    return isinstance(value, str) and value.startswith('https://')


def digest(value):
    return isinstance(value, str) and len(value) == 64 and all(c in '0123456789abcdef' for c in value)


def check_rankings(rankings, markets, require_all=True):
    issues = []
    expected = set(COUNTRIES)
    geography = {m['id']: m for m in markets}
    if len(markets) != len(COUNTRIES) or set(geography) != expected:
        issues.append('World geography must retain prior markets and include all twenty economies.')
    if [geography.get(c, {}).get('areaRank') for c in RETAINED_COUNTRIES[:-1]] != list(range(1, 31)) or any(geography.get(c, {}).get('areaRank') is not None for c in expected - set(RETAINED_COUNTRIES[:-1])):
        issues.append('Retained geography area ranks are invalid.')
    if [geography.get(c, {}).get('economyRank') for c in ECONOMY_COUNTRIES] != list(range(1, 21)) or any(geography.get(c, {}).get('economyRank') is not None for c in expected - set(ECONOMY_COUNTRIES)):
        issues.append('Economic coverage ranks differ from the agreed IMF nominal GDP list.')
    if {m['id'] for m in markets if m.get('requiresLogos')} != LOGO_COUNTRIES:
        issues.append('Mandatory logo markets differ from the retained prepared markets.')
    if any(geography.get(c, {}).get('currency') != currency for c, currency in CURRENCIES.items()):
        issues.append('Bank country currency mapping is invalid.')
    if rankings.get('version') != 1 or rankings.get('scope') != SCOPE:
        issues.append('Unsupported world ranking scope.')
    try:
        source = rankings['economySource']
        if source['dataset'] != 'IMF.RES:WEO(9.0.0)' or source['release'] != 'April 2026' or source['indicator'] != 'NGDPD' or type(source['year']) is not int or source['year'] != 2025 or source['unit'] != 'Billions of current US dollars':
            raise ValueError('Expected the agreed IMF NGDPD 2025 release')
        if not https(source['url']) or not digest(source['sha256']) or not source['methodology'].strip():
            raise ValueError('GDP source provenance missing')
        if date.fromisoformat(source['publicationDate']) > date.fromisoformat(source['retrievedOn']):
            raise ValueError('GDP source publication date is after retrieval')
        values = source['values']
        if [row['country'] for row in values] != ECONOMY_COUNTRIES or any(type(row['rank']) is not int for row in values) or [row['rank'] for row in values] != list(range(1, 21)):
            raise ValueError('GDP source does not match the agreed twenty economies')
        amounts = [Decimal(str(row['gdpBillionsUSD'])) for row in values]
        if any(not amount.is_finite() or amount <= 0 for amount in amounts) or any(a <= b for a, b in zip(amounts, amounts[1:])):
            raise ValueError('GDP values must be positive and in descending order')
    except (KeyError, TypeError, ValueError, InvalidOperation) as exc:
        issues.append('Economic scope source invalid: ' + str(exc) + '.')
    countries = rankings.get('countries', {})
    if set(countries) - expected:
        issues.append('Unexpected country ranking.')
    seen = set()
    for country in COUNTRIES:
        dataset = countries.get(country)
        if not dataset:
            if require_all and country in ECONOMY_COUNTRIES: issues.append('World ranking unavailable: ' + country + '.')
            continue
        if require_all and country in ECONOMY_COUNTRIES and dataset.get('reviewPending'):
            issues.append('World ranking review pending in ' + country + ': ' + dataset['reviewPending'])
        try:
            if date.fromisoformat(dataset['effectiveOn']) > date.fromisoformat(dataset['retrievedOn']):
                raise ValueError('Ranking effective date is after retrieval')
            if not https(dataset['url']) or not dataset['basis'].strip():
                raise ValueError('Ranking provenance missing')
            if country not in LEGACY and not digest(dataset.get('sourceSHA256')):
                raise ValueError('Ranking source digest missing')
            records = dataset['banks']
            count = len(records)
            if count != 20:
                proof = dataset.get('smallSystem', {})
                if not 0 < count < 20 or type(proof.get('activeBanks')) is not int or proof['activeBanks'] != count or not https(proof.get('url')) or not digest(proof.get('sourceSHA256')):
                    raise ValueError('A smaller system needs regulator evidence for all active banks')
                if date.fromisoformat(proof['effectiveOn']) > date.fromisoformat(dataset['retrievedOn']):
                    raise ValueError('Regulator evidence date is after retrieval')
            if any(type(b['rank']) is not int for b in records) or [b['rank'] for b in records] != list(range(1, count + 1)):
                raise ValueError('Ranks must be consecutive and in source order')
            ordering = dataset.get('ordering', 'verified-assets')
            if ordering not in ('verified-assets', 'approximate-size'):
                raise ValueError('Unknown bank ordering basis')
            previous = None
            for bank in records:
                identity = bank['id']
                if not isinstance(identity, str) or not identity or identity in seen:
                    raise ValueError('Duplicate or empty bank identity')
                seen.add(identity)
                if not bank['name'].strip() or not bank.get('legalName', bank['name']).strip():
                    raise ValueError('Bank name missing')
                # Ranked rows must describe active banks. In particular, a
                # string such as "false" must not enter the Boolean field of
                # the generated catalogue or override a registry closure.
                status = bank.get('active', True)
                if type(status) is not bool or not status:
                    raise ValueError('Ranked bank must be active with a boolean status')
                if ordering == 'approximate-size':
                    verified = date.fromisoformat(bank['activeVerifiedOn'])
                    retrieved = date.fromisoformat(dataset['retrievedOn'])
                    if not 0 <= (retrieved - verified).days <= 366:
                        raise ValueError('Current bank identity verification is missing or stale')
                    evidence = bank['activeSource']
                    if not https(evidence['url']) or not digest(evidence['sha256']):
                        raise ValueError('Current bank identity provenance missing')
                if bank.get('assets') is not None:
                    amount = Decimal(str(bank['assets']))
                    if not amount.is_finite() or amount <= 0 or (previous is not None and amount > previous):
                        raise ValueError('Assets must be positive and in descending order')
                    if not dataset.get('assetUnit'):
                        raise ValueError('Asset unit missing')
                    previous = amount
                elif ordering != 'approximate-size' and not bank.get('publishedRank') and country not in LEGACY:
                    raise ValueError('Assets or published ranking position missing')
            for bank in dataset.get('additionalBanks', []):
                identity = bank['id']
                if not isinstance(identity, str) or not identity or identity in seen:
                    raise ValueError('Duplicate or empty additional bank identity')
                seen.add(identity)
                if not bank['name'].strip() or not bank.get('legalName', bank['name']).strip():
                    raise ValueError('Additional bank name missing')
                if 'rank' in bank or 'assetRank' in bank or 'rankingSource' in bank:
                    raise ValueError('Additional banks cannot have an invented ranking')
                if type(bank.get('active', True)) is not bool:
                    raise ValueError('Additional bank status must be boolean')
        except (KeyError, TypeError, ValueError, InvalidOperation) as exc:
            issues.append('World ranking invalid in ' + country + ': ' + str(exc) + '.')
    return issues


def apply_rankings(catalog, rankings, markets):
    """Retain registry and historical identities; augment only reviewed ranking rows."""
    malformed = check_rankings(rankings, markets, require_all=False)
    if malformed: raise ValueError('; '.join(malformed))
    # Partial development builds may omit markets, but must never turn an
    # explicitly unreviewed economic-country candidate list into live ranks.
    pending = sorted(country for country, dataset in rankings['countries'].items()
                     if country in ECONOMY_COUNTRIES and dataset.get('reviewPending'))
    if pending:
        raise ValueError('Economic ranking review pending: ' + ', '.join(pending) + '.')
    # Reconcile against a private staging copy. A country/status mismatch in a
    # later market must not erase existing ranks or leave earlier rows imported.
    original = catalog
    catalog = deepcopy(catalog)
    by_id = {b['id']: b for b in catalog['banks']}
    for bank in catalog['banks']:
        bank.pop('assetRank', None)
        bank.pop('rankingSource', None)
    for country, dataset in rankings['countries'].items():
        for row in dataset.get('additionalBanks', []) + dataset['banks']:
            ranked = 'rank' in row
            identity = row['id']
            bank = by_id.get(identity)
            if bank is None:
                if country in LEGACY: raise ValueError('Legacy ranked identity missing: ' + identity)
                bank = dict(id=identity, name=row['name'], legalName=row.get('legalName', row['name']), country=country,
                            type=row.get('type', 'bank'), aliases=row.get('aliases', []), regulatorIDs=row.get('regulatorIDs', {}),
                            active=row.get('active', True), website=row.get('website'))
                catalog['banks'].append(bank)
                by_id[identity] = bank
            if bank['country'] != country or (ranked and not bank['active']):
                raise ValueError('Ranked bank country / status mismatch: ' + identity)
            if country not in LEGACY:
                if not ranked:
                    bank['active'] = row.get('active', True)
                bank['name'] = row['name']
                bank['legalName'] = row.get('legalName', row['name'])
                if 'type' in row: bank['type'] = row['type']
                bank['aliases'] = sorted(set(bank.get('aliases', []) + row.get('aliases', [])))
                bank['regulatorIDs'] = {**bank.get('regulatorIDs', {}), **row.get('regulatorIDs', {})}
            if ranked:
                bank['assetRank'] = row['rank']
                bank['rankingSource'] = dataset['url']
    manifest = catalog['manifest']
    manifest.update(version=4, nameScope=SCOPE, rankingScope=SCOPE)
    manifest['notes'] = [note for note in manifest.get('notes', []) if not note.startswith('World ranking')]
    manifest['notes'] += check_rankings(rankings, markets)
    manifest['logosComplete'] = False
    manifest['logoScope'] = SCOPE
    original.clear()
    original.update(catalog)
    return original


def inspect_world(path, catalog, brands):
    issues = []
    try:
        rankings = json.loads((path.parent / 'bank-rankings.json').read_text())
        markets = json.loads((path.parent / 'bank-markets.json').read_text())
        issues += check_rankings(rankings, markets)
        if catalog['manifest'].get('nameScope') != SCOPE or catalog['manifest'].get('rankingScope') != SCOPE:
            issues.append('World release coverage scope is missing.')
        by_id = {b['id']: b for b in catalog['banks']}
        expected_ranks = {}
        required_logos = set()
        for country, dataset in rankings['countries'].items():
            for row in dataset.get('additionalBanks', []):
                bank = by_id.get(row['id'])
                if not bank or bank['country'] != country or bank['active'] != row.get('active', True):
                    issues.append('Additional bank country / status is not reconciled: ' + row['id'] + '.')
                if bank and country not in LEGACY and (bank['name'] != row['name'] or bank.get('legalName') != row.get('legalName', row['name'])):
                    issues.append('Additional bank name is not reconciled: ' + row['id'] + '.')
            for row in dataset['banks']:
                expected_ranks[row['id']] = row['rank']
                bank = by_id.get(row['id'])
                if not bank or bank['country'] != country or not bank['active'] or bank.get('assetRank') != row['rank'] or bank.get('rankingSource') != dataset['url']:
                    issues.append('Ranked bank is not reconciled: ' + row['id'] + '.')
                if bank and country not in LEGACY and (bank['name'] != row['name'] or bank.get('legalName') != row.get('legalName', row['name'])):
                    issues.append('Ranked bank name is not reconciled: ' + row['id'] + '.')
                if country in LOGO_COUNTRIES: required_logos.add(row['id'])
        for bank in catalog['banks']:
            if bank.get('assetRank') != expected_ranks.get(bank['id']):
                issues.append('Unexpected bank rank: ' + bank['id'] + '.')
        targets = brands.get('targets', [])
        actual_logos = {t['bankID'] for t in targets}
        if brands.get('scope') != SCOPE or len(actual_logos) != len(targets) or not required_logos.issubset(actual_logos):
            issues.append('World mandatory logo targets do not match ranked banks.')
        for target in targets:
            bank = by_id.get(target['bankID'])
            if not bank or target.get('country') != bank['country'] or target['bankID'] not in expected_ranks:
                issues.append('World logo target has no matching ranked bank: ' + target['bankID'] + '.')
            if target.get('rank') != expected_ranks.get(target['bankID']):
                issues.append('World logo rank does not match bank ranking: ' + target['bankID'] + '.')
        # A missing country's dataset must never silently reduce the logo scope.
        if not set(ECONOMY_COUNTRIES).issubset(rankings['countries']):
            issues.append('Mandatory economic countries are missing from ranking data.')
        return issues, required_logos
    except (OSError, KeyError, TypeError, ValueError) as exc:
        issues.append('World catalogue metadata invalid: ' + str(exc))
        return issues, set()
