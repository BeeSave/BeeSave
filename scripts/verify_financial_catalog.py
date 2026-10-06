"""Audit bundled banks and logo provenance; --require-complete gates a financial release."""
import argparse
import hashlib
import json
import struct
from datetime import date
from pathlib import Path


def required_logo_ids(path, banks, issues):
    """The agreed logo scope is explicit; catalogue completeness cannot waive targets."""
    try:
        brands = json.loads((path.parent / 'bank-brands.json').read_text())
        if brands.get('version') != 1 or brands.get('scope') != 'top20-per-market':
            raise ValueError('Unsupported logo scope')
        targets = brands['targets']
        ids = [item['bankID'] for item in targets]
        if len(ids) != 60 or len(set(ids)) != 60:
            raise ValueError('Expected sixty distinct logo targets')
        by_id = {bank['id']: bank for bank in banks}
        for market in ('RU', 'US', 'GB'):
            market_targets = [item for item in targets if item['country'] == market]
            if sorted(item['rank'] for item in market_targets) != list(range(1, 21)):
                raise ValueError('Expected ranks 1–20 in ' + market)
            source = brands['rankingSources'][market]
            date.fromisoformat(source['effectiveOn'])
            if not source['url'].startswith('https://') or not source['basis']:
                raise ValueError('Ranking provenance missing for ' + market)
        for item in targets:
            bank = by_id.get(item['bankID'])
            if not bank or not bank['active'] or bank['country'] != item['country']:
                raise ValueError('Logo target identity / market mismatch: ' + item['bankID'])
            for key in ('logoResource', 'logoSHA256', 'logoSource', 'logoUsage', 'logoCheckedOn'):
                if item.get(key) != bank.get(key):
                    raise ValueError('Logo target provenance mismatch: ' + item['bankID'])
            original_hash = item.get('logoOriginalSHA256', '')
            if len(original_hash) != 64 or any(c not in '0123456789abcdef' for c in original_hash):
                raise ValueError('Original logo digest unavailable: ' + item['bankID'])
            if item.get('usageReview') == 'pending':
                issues.append('Logo usage review pending: ' + item['bankID'])
        return set(ids)
    except (OSError, KeyError, ValueError, TypeError) as exc:
        issues.append('Required top-twenty logo manifest invalid: ' + str(exc))
        return set()


def inspect(path: Path) -> dict:
    catalog = json.loads(path.read_text())
    manifest, banks = catalog['manifest'], catalog['banks']
    issues = []
    # Approved release scope guarantees twenty banks per market. Additional
    # registry names remain useful without claiming complete market coverage.
    if manifest.get('nameScope') != 'top20-per-market' or manifest.get('logoScope') != 'top20-per-market':
        issues.append('Unsupported or inconsistent release coverage scope.')
    if not manifest.get('logosComplete'):
        issues.append('Logos: sixty verified top-twenty brand resources are unavailable.')
    required_logos = required_logo_ids(path, banks, issues)
    ids = [bank['id'] for bank in banks]
    if len(ids) != len(set(ids)):
        issues.append('Duplicate bank identifiers.')
    for market in ('RU', 'US', 'GB'):
        if not any(bank['country'] == market and bank['active'] for bank in banks):
            issues.append(f'No active records for {market}.')
    for source in manifest['sources']:
        members = source.get('members')
        present = {identity for bank in banks for identity in bank.get('sourceIDs', [bank['id']])}
        if members is None or len(members) != source.get('records') or len(members) != len(set(members)) or not set(members).issubset(present):
            issues.append(f'Source members are not fully reconciled: {source["name"]}.')
        if not source.get('complete') or not source.get('effectiveOn') or not source.get('retrievedOn'):
            issues.append(f'Source coverage / effective date is unconfirmed: {source["name"]}.')
        for key in ('effectiveOn', 'retrievedOn'):
            if source.get(key):
                try:
                    date.fromisoformat(source[key])
                except ValueError:
                    issues.append(f'Invalid {key}: {source["name"]}.')
    valid_logos, missing_logos, verified_ids = 0, 0, set()
    for bank in banks:
        # Logos outside the explicit top twenty in each market are optional.
        resource = bank.get('logoResource')
        if not resource:
            missing_logos += int(bank['active'])
            continue
        relative = Path(resource)
        valid = not relative.is_absolute() and '..' not in relative.parts
        logo = path.parent / 'BankLogos' / relative
        valid = valid and logo.is_file()
        if valid:
            data = logo.read_bytes()
            valid = len(data) <= 2 * 1024 * 1024 and data.startswith(b'\x89PNG\r\n\x1a\n')
            if valid:
                valid = len(data) >= 24 and all(0 < size <= 4096 for size in struct.unpack('>II', data[16:24]))
            valid = valid and hashlib.sha256(data).hexdigest() == bank.get('logoSHA256')
        valid = valid and all(bank.get(key) for key in ('logoSource', 'logoUsage', 'logoCheckedOn'))
        if valid:
            try:
                date.fromisoformat(bank['logoCheckedOn'])
                valid = bank['logoSource'].startswith('https://')
            except ValueError:
                valid = False
        if valid:
            valid_logos += 1
            verified_ids.add(bank['id'])
        else:
            issues.append(f'Logo resource / hash / provenance invalid: {bank["id"]}.')
    missing_required = sorted(required_logos - verified_ids)
    for identity in missing_required:
        issues.append('Required top-twenty logo unavailable: ' + identity + '.')
    issues.extend(manifest.get('notes', []))
    return {'status': 'ready' if not issues else 'incomplete', 'records': len(banks),
            'activeByMarket': {market: sum(bank['active'] and bank['country'] == market for bank in banks) for market in ('RU', 'US', 'GB')},
            'verifiedLogos': valid_logos, 'requiredLogos': len(required_logos),
            'verifiedRequiredLogos': len(required_logos & verified_ids),
            'missingRequiredLogos': missing_required, 'missingActiveLogos': missing_logos, 'namesComplete': bool(manifest.get('namesComplete')),
            'coverageNotes': manifest.get('coverageNotes', []), 'issues': issues}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--catalog', type=Path, default=Path(__file__).resolve().parent.parent / 'Sources/BudgetCore/Resources/banks.json')
    parser.add_argument('--require-complete', action='store_true')
    args = parser.parse_args()
    result = inspect(args.catalog)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    raise SystemExit(2 if args.require_complete and result['status'] != 'ready' else 0)
