#!/usr/bin/env python3
"""Prepare offline public bank metadata. Never fetch logos from user selections.

Names and image rights are separate acceptance gates. A downloaded FDIC list
does not prove coverage of uninsured banks, state registers or credit unions.
"""
import argparse
from datetime import datetime, timezone
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
SOURCES = {
    'cbr': 'https://cbr.ru/banking_sector/credit/FullCoList/',
    'pra': 'https://www.bankofengland.co.uk/prudential-regulation/authorisations/which-firms-does-the-pra-regulate',
    'fdic': 'https://api.fdic.gov/banks/institutions?' + urllib.parse.urlencode({'filters': 'ACTIVE:1', 'fields': 'NAME,CERT,ACTIVE,WEBADDR,RSSDID', 'limit': 10000, 'format': 'json'}),
}

class Tables(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.tables = []; self.section = ''; self.table = None; self.row = None; self.cell = None; self.heading = None; self.headings = []

    def handle_starttag(self, tag, attrs):
        if tag in ('h1', 'h2', 'h3'): self.heading = []
        if tag == 'table': self.table = {'section': self.section, 'rows': []}
        elif tag == 'tr' and self.table is not None: self.row = []
        elif tag in ('td', 'th') and self.row is not None: self.cell = []

    def handle_data(self, data):
        if self.heading is not None: self.heading.append(data)
        if self.cell is not None: self.cell.append(data)

    def handle_endtag(self, tag):
        if tag in ('h1', 'h2', 'h3') and self.heading is not None:
            text = ' '.join(''.join(self.heading).split()); self.headings.append(text); lower = text.lower()
            if 'building societ' in lower: self.section = 'buildingSociety'
            elif 'credit union' in lower: self.section = 'creditUnion'
            elif 'banks we regulate' in lower or lower == 'uk banks': self.section = 'bank'
            elif 'insurer' in lower or 'investment firm' in lower: self.section = 'excluded'
            self.heading = None
        elif tag in ('td', 'th') and self.cell is not None:
            self.row.append(' '.join(''.join(self.cell).split())); self.cell = None
        elif tag == 'tr' and self.row is not None:
            self.table['rows'].append(self.row); self.row = None
        elif tag == 'table' and self.table is not None:
            self.tables.append(self.table); self.table = None

def fetch(source, cache, allow_network):
    path = cache / (source + '.data')
    if not allow_network:
        return path.read_bytes()
    request = urllib.request.Request(SOURCES[source], headers={'User-Agent': 'BeeSave catalog builder / public registry import', 'Accept': 'application/json,text/html'})
    with urllib.request.urlopen(request, timeout=15) as response:
        if urllib.parse.urlparse(response.url).hostname != urllib.parse.urlparse(SOURCES[source]).hostname:
            raise ValueError('Unexpected registry redirect')
        data = response.read(20 * 1024 * 1024 + 1)
        if len(data) > 20 * 1024 * 1024: raise ValueError('Registry response exceeds 20 MiB')
    cache.mkdir(parents=True, exist_ok=True); path.write_bytes(data)
    return data

def record(identifier, name, country, kind='bank', regulator_ids=None, active=True, website=None):
    return dict(id=identifier, name=name, legalName=name, country=country, type=kind, aliases=[], regulatorIDs=regulator_ids or {}, active=active, website=website)

def parse_cbr(data):
    page = data.decode('utf-8-sig'); parser = Tables(); parser.feed(page)
    records = []
    for table in parser.tables:
        for row in table['rows']:
            if len(row) < 9 or not row[0].isdigit() or not row[2].isdigit(): continue
            number = row[2]; kind = 'nonBank' if 'НКО' in row[1] else 'bank'
            active = row[7].lower() == 'действующая'
            records.append(record('ru-cbr-' + number, row[4], 'RU', kind, {'CBR': number, 'OGRN': row[3]}, active=active))
    if len(records) < 100: raise ValueError('CBR table topology / record count changed')
    date = re.search(r'по состоянию на\s+(\d{2})\.(\d{2})\.(\d{4})', ' '.join(parser.headings))
    unique = {}
    for bank in records:
        if bank['id'] in unique and bank != unique[bank['id']]: raise ValueError('Conflicting CBR identity')
        unique[bank['id']] = bank
    records = list(unique.values())
    return records, '-'.join((date[3], date[2], date[1])) if date else None

def parse_pra(data):
    parser = Tables(); parser.feed(data.decode('utf-8-sig')); records = []
    for table in parser.tables:
        if table['section'] not in ('bank', 'buildingSociety', 'creditUnion'): continue
        for row in table['rows']:
            if len(row) < 2 or not row[1].isdigit(): continue
            frn = row[1]; identifiers = {'FRN': frn}
            if len(row) > 2 and row[2]: identifiers['LEI'] = row[2].lstrip("'")
            records.append(record('gb-pra-' + frn, row[0], 'GB', table['section'], identifiers))
    if len(records) < 200: raise ValueError('PRA table topology / record count changed')
    return records, None

def parse_fdic(data):
    payload = json.loads(data); rows = payload['data']; records = []
    total = payload.get('meta', {}).get('total', payload.get('total'))
    if isinstance(total, dict): total = total.get('value')
    if total is None or len(rows) != int(total): raise ValueError('FDIC results are truncated or total is unavailable')
    for item in rows:
        bank = item.get('data', item); cert = str(bank['CERT']); identifiers = {'FDIC': cert}
        if bank.get('RSSDID'): identifiers['RSSD'] = str(bank['RSSDID'])
        records.append(record('us-fdic-' + cert, bank['NAME'], 'US', regulator_ids=identifiers, website=bank.get('WEBADDR')))
    if len(records) < 1000: raise ValueError('FDIC record count unexpectedly small')
    return records, None

def build(cache, allow_network, logos=None):
    banks = []; sources = []; notes = []; parsers = {'cbr': parse_cbr, 'pra': parse_pra, 'fdic': parse_fdic}
    today = datetime.now(timezone.utc).date().isoformat()
    for key, parser in parsers.items():
        try:
            data = fetch(key, cache, allow_network); parsed, effective = parser(data); banks.extend(parsed)
            sources.append(dict(name=key.upper(), url=SOURCES[key], retrievedOn=today if allow_network else None, effectiveOn=effective, records=len(parsed), complete=True, sha256=hashlib.sha256(data).hexdigest()))
        except Exception as exc:
            sources.append(dict(name=key.upper(), url=SOURCES[key], retrievedOn=None, effectiveOn=None, records=0, complete=False))
            notes.append(key.upper() + ': ' + str(exc))
    ids = [row['id'] for row in banks]
    if len(ids) != len(set(ids)): raise ValueError('Duplicate regulator identity')
    approved = json.loads(logos.read_text()) if logos else {}
    for bank in banks:
        item = approved.get(bank['id'])
        if not item: continue
        path = ROOT / 'Sources/BudgetCore/Resources/BankLogos' / item['resource']
        if path.parent != ROOT / 'Sources/BudgetCore/Resources/BankLogos' or not path.is_file(): raise ValueError('Unsafe or missing local image')
        if hashlib.sha256(path.read_bytes()).hexdigest() != item['sha256'] or not item.get('source') or not item.get('usage'): raise ValueError('Image is not verified')
        bank.update(logoResource=item['resource'], logoSource=item['source'], logoUsage=item['usage'], logoSHA256=item['sha256'], logoCheckedOn=item.get('checkedOn', today))
    notes.extend(['US: необходимо объединить NIC/OCC, реестры штатов и NCUA; FDIC не покрывает все банки.', 'RU: требуется отдельная сверка допущенных иностранных банковских подразделений.', 'Логотипы: нужны проверенные ресурсы и основания использования; заглушки не засчитываются.'])
    covered = [scope for source, scope in [('CBR', 'ru_credit_institutions'), ('PRA', 'gb_pra'), ('FDIC', 'us_fdic')] if any(item['name'] == source and item['complete'] for item in sources)]
    manifest = dict(version=1, builtOn=today, sources=sources, coveredScopes=covered, namesComplete=False, logosComplete=False, notes=notes)
    return dict(manifest=manifest, banks=sorted(banks, key=lambda bank: (bank['country'], bank['id'])))

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--allow-network', action='store_true'); parser.add_argument('--cache', type=Path, required=True); parser.add_argument('--output', type=Path, default=ROOT / 'Sources/BudgetCore/Resources/banks.json'); parser.add_argument('--logos', type=Path)
    args = parser.parse_args(); result = build(args.cache, args.allow_network, args.logos)
    if not result['banks']: raise SystemExit('No registry data; previous catalog preserved')
    args.output.parent.mkdir(parents=True, exist_ok=True); args.output.write_text(json.dumps(result, ensure_ascii=False, separators=(',', ':')) + '\n')
    print(json.dumps({'records': len(result['banks']), 'sources': result['manifest']['sources'], 'namesComplete': False, 'logosComplete': False}, ensure_ascii=False))

if __name__ == '__main__': main()
