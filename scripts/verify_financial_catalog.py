"""Audit bundled banks and logo provenance; --require-complete gates a financial release."""
import argparse
import hashlib
import json
import struct
from datetime import date
from pathlib import Path


def inspect(path: Path) -> dict:
    catalog = json.loads(path.read_text())
    manifest, banks = catalog['manifest'], catalog['banks']
    issues = []
    required_scopes = {'ru_credit_institutions', 'ru_foreign_branches', 'us_fdic', 'us_nic', 'us_occ', 'us_state_banks', 'us_ncua', 'us_state_credit_unions', 'gb_pra'}
    for scope in sorted(required_scopes - set(manifest.get('coveredScopes', []))):
        issues.append(f'Regulator scope not reconciled: {scope}.')
    if not manifest.get('namesComplete'):
        issues.append('Names: full RU/US/GB regulator coverage has not been confirmed.')
    if not manifest.get('logosComplete'):
        issues.append('Logos: complete verified local brand resources are unavailable.')
    ids = [bank['id'] for bank in banks]
    if len(ids) != len(set(ids)):
        issues.append('Duplicate bank identifiers.')
    for market in ('RU', 'US', 'GB'):
        if not any(bank['country'] == market and bank['active'] for bank in banks):
            issues.append(f'No active records for {market}.')
    for source in manifest['sources']:
        if not source.get('complete') or not source.get('effectiveOn') or not source.get('retrievedOn'):
            issues.append(f'Source coverage / effective date is unconfirmed: {source["name"]}.')
        for key in ('effectiveOn', 'retrievedOn'):
            if source.get(key):
                try:
                    date.fromisoformat(source[key])
                except ValueError:
                    issues.append(f'Invalid {key}: {source["name"]}.')
    valid_logos, missing_logos = 0, 0
    for bank in banks:
        # Inactive historical records are retained for account lookup; brands are mandatory for active institutions.
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
            valid_logos += 1
        else:
            issues.append(f'Logo resource / hash / provenance invalid: {bank["id"]}.')
    if missing_logos:
        issues.append(f'Active institutions without a verified logo: {missing_logos}.')
    issues.extend(manifest.get('notes', []))
    return {'status': 'ready' if not issues else 'incomplete', 'records': len(banks),
            'activeByMarket': {market: sum(bank['active'] and bank['country'] == market for bank in banks) for market in ('RU', 'US', 'GB')},
            'verifiedLogos': valid_logos, 'missingActiveLogos': missing_logos, 'issues': issues}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--catalog', type=Path, default=Path(__file__).resolve().parent.parent / 'Sources/BudgetCore/Resources/banks.json')
    parser.add_argument('--require-complete', action='store_true')
    args = parser.parse_args()
    result = inspect(args.catalog)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    raise SystemExit(2 if args.require_complete and result['status'] != 'ready' else 0)
