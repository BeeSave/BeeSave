"""Offline parsers for official NIC, NCUA, OCC and CBR registry exports.

Only public organization identifiers and names enter the application catalog.
Addresses, tax identifiers, named contacts and call-report financials are discarded.
"""
import csv
from datetime import date, datetime
import io
from pathlib import PurePosixPath
import re
from xml.etree import ElementTree as ET
from zipfile import ZipFile

MAX_XML = 20 * 1024 * 1024
MAX_CSV = 256 * 1024 * 1024
NS = {'s': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
US_BANK_TYPES = {'NAT', 'NMB', 'SMB', 'SSB', 'SAL', 'FSB', 'CSA', 'CPB', 'EDB', 'AGB', 'MTC', 'NTC'}
US_BRANCH_TYPES = {'IFB', 'ISB', 'UFA', 'UFB', 'USA', 'USB'}
US_CU_TYPES = {'FCU', 'SCU'}

def archive_member(archive, name, maximum):
    item = archive.getinfo(name)
    if item.file_size > maximum or item.flag_bits & 1:
        raise ValueError('Oversized or encrypted registry member')
    data = archive.read(name)  # verifies CRC, without extracting filesystem paths
    if len(data) != item.file_size:
        raise ValueError('Truncated registry member')
    return data

def zipped_csv(data, filename, encoding='utf-8-sig'):
    with ZipFile(io.BytesIO(data)) as archive:
        matches = [name for name in archive.namelist() if PurePosixPath(name).name.casefold() == filename.casefold()]
        if len(matches) != 1:
            raise ValueError('Required registry table is missing or ambiguous: ' + filename)
        content = archive_member(archive, matches[0], MAX_CSV).decode(encoding)
    return list(csv.DictReader(io.StringIO(content)))

def xlsx_tables(data):
    with ZipFile(io.BytesIO(data)) as archive:
        def xml(name):
            raw = archive_member(archive, name, MAX_XML)
            if b'<!DOCTYPE' in raw or b'<!ENTITY' in raw:
                raise ValueError('Unsupported registry XML declaration')
            return ET.fromstring(raw)
        strings = []
        if 'xl/sharedStrings.xml' in archive.namelist():
            strings = [''.join(t.text or '' for t in item.findall('.//s:t', NS)) for item in xml('xl/sharedStrings.xml').findall('s:si', NS)]
        tables = []
        for name in archive.namelist():
            if not re.fullmatch(r'xl/worksheets/sheet\d+\.xml', name):
                continue
            rows = []
            for row in xml(name).findall('.//s:row', NS):
                values = {}
                for cell in row.findall('s:c', NS):
                    column = re.match('[A-Z]+', cell.attrib['r'])[0]
                    position = 0
                    for letter in column:
                        position = position * 26 + ord(letter) - ord('A') + 1
                    value = cell.find('s:v', NS)
                    text = value.text or '' if value is not None else ''.join(t.text or '' for t in cell.findall('.//s:t', NS))
                    if cell.get('t') == 's' and text:
                        text = strings[int(text)]
                    values[position - 1] = text.strip()
                rows.append([values.get(i, '') for i in range(max(values, default=-1) + 1)])
            tables.append(rows)
        return tables

def public_ids(row, columns):
    result = {}
    for regulator, column in columns.items():
        value = str(row.get(column, '')).strip()
        if value not in ('', '0'):
            if not value.isdigit():
                raise ValueError('Invalid regulator identifier: ' + regulator)
            result[regulator] = str(int(value))
    return result

def nic_date(value):
    return datetime.strptime(value.split()[0], '%m/%d/%Y').date()

def parse_nic(data, record, branches=False, as_of=None, parent_names=None):
    as_of = as_of or date.today()
    filename = 'CSV_ATTRIBUTES_BRANCHES.CSV' if branches else 'CSV_ATTRIBUTES_ACTIVE.CSV'
    rows = zipped_csv(data, filename)
    required = {'#ID_RSSD', 'ENTITY_TYPE', 'NM_LGL', 'DOMESTIC_IND', 'D_DT_EXIST_TERM', 'D_DT_END'}
    if not rows or not required.issubset(rows[0]):
        raise ValueError('NIC schema changed')
    records = []
    names = {row['#ID_RSSD'].strip(): row['NM_LGL'].strip() for row in rows}
    for row in rows:
        entity = row['ENTITY_TYPE'].strip()
        if entity not in (US_BRANCH_TYPES if branches else US_BANK_TYPES | US_CU_TYPES) or row['DOMESTIC_IND'].strip() != 'Y':
            continue
        if nic_date(row['D_DT_EXIST_TERM']) <= as_of or nic_date(row['D_DT_END']) <= as_of:
            continue
        identifiers = public_ids(row, {'RSSD': '#ID_RSSD', 'FDIC': 'ID_FDIC_CERT', 'OCC': 'ID_OCC', 'NCUA': 'ID_NCUA'})
        name = row['NM_LGL'].strip()
        parent_name = (parent_names or {}).get(row.get('ID_RSSD_HD_OFF', '').strip()) if branches else None
        if parent_name:
            name = parent_name + ' · ' + name
        kind = 'foreignBranch' if branches else 'creditUnion' if entity in US_CU_TYPES else 'bank'
        bank = record('us-nic-' + identifiers['RSSD'], name, 'US', kind, identifiers, website=row.get('URL', '').strip() or None)
        bank['nicEntityType'] = entity
        if branches:
            bank['parentRegulatorID'] = row.get('ID_RSSD_HD_OFF', '').strip()
        records.append(bank)
    return records, names

def parse_ncua(data, record):
    rows = zipped_csv(data, 'FOICU.txt', encoding='cp1252')
    if not rows or not {'CU_NUMBER', 'RSSD', 'CU_NAME', 'CYCLE_DATE'}.issubset(rows[0]):
        raise ValueError('NCUA schema changed')
    dates = {datetime.strptime(row['CYCLE_DATE'].split()[0], '%m/%d/%Y').date().isoformat() for row in rows}
    if len(dates) != 1:
        raise ValueError('NCUA cycle dates differ')
    records = []
    for row in rows:
        identifiers = public_ids(row, {'NCUA': 'CU_NUMBER', 'RSSD': 'RSSD'})
        bank = record('us-ncua-' + identifiers['NCUA'], row['CU_NAME'].strip(), 'US', 'creditUnion', identifiers)
        records.append(bank)
    return records, dates.pop()

def parse_occ(data, record):
    records, effective = [], set()
    for rows in xlsx_tables(data):
        header = next((i for i, row in enumerate(rows) if 'CHARTER NO' in row and 'RSSD' in row), None)
        if header is None:
            continue
        title = ' '.join(value for row in rows[:header] for value in row)
        match = re.search(r'[Aa]s [Oo]f (\d{1,2}/\d{1,2}/\d{4})', title)
        if not match:
            raise ValueError('OCC effective date missing')
        effective.add(datetime.strptime(match[1], '%m/%d/%Y').date().isoformat())
        for values in rows[header + 1:]:
            row = dict(zip(rows[header], values))
            if not row.get('CHARTER NO', '').isdigit() or not row.get('NAME'):
                continue
            identifiers = public_ids(row, {'OCC': 'CHARTER NO', 'RSSD': 'RSSD', 'FDIC': 'CERT'})
            kind = 'foreignBranch' if 'Branches' in title else 'bank'
            records.append(record('us-occ-' + identifiers['OCC'], row['NAME'], 'US', kind, identifiers))
    if not records or len(effective) != 1:
        raise ValueError('OCC table topology / dates changed')
    return records, effective.pop()

def parse_cbr_foreign(data, record):
    tables = xlsx_tables(data)
    table = next((rows for rows in tables if any('Полное наименование филиала иностранного банка' in row for row in rows)), None)
    if table is None:
        raise ValueError('CBR foreign branch registry header missing')
    records = []
    for row in table:
        if len(row) < 26 or row[15] == '16' or not row[15].isdigit():
            continue
        identifier = row[15]
        name = row[10] or row[9]
        bank = record('ru-cbr-foreign-' + identifier, name, 'RU', 'foreignBranch', {'CBR_BRANCH': identifier}, active=not any(row[i] for i in (22, 24, 25)), website=row[14] or row[8])
        bank['aliases'] = [value for value in (row[1], row[2], row[9]) if value and value != name]
        records.append(bank)
    # A verified official registry with headers and no licenses is a valid empty snapshot.
    return records

def merge_regulator_records(banks):
    output, identities = [], {}
    for bank in banks:
        bank.setdefault('sourceIDs', [bank['id']])
        keys = [(bank['country'], regulator, value) for regulator, value in bank['regulatorIDs'].items() if regulator != 'OGRN']
        matches = {identities[key] for key in keys if key in identities}
        if len(matches) > 1:
            raise ValueError('Conflicting cross-regulator identities')
        if not matches:
            index = len(output); output.append(bank)
        else:
            index = matches.pop(); existing = output[index]
            for key, value in bank['regulatorIDs'].items():
                if key in existing['regulatorIDs'] and existing['regulatorIDs'][key] != value:
                    if bank.get('registryEffectiveOn') and existing.get('registryEffectiveOn') and bank['registryEffectiveOn'] < existing['registryEffectiveOn']:
                        existing.setdefault('historicalRegulatorIDs', []).append({'regulator': key, 'value': value, 'effectiveOn': bank['registryEffectiveOn']})
                    else:
                        raise ValueError('Conflicting regulator ID: ' + existing['id'])
                else:
                    existing['regulatorIDs'][key] = value
            existing['aliases'] = sorted(set(existing['aliases'] + bank['aliases'] + ([bank['name']] if bank['name'] != existing['name'] else [])))
            existing['sourceIDs'] = sorted(set(existing['sourceIDs'] + bank['sourceIDs']))
            if not existing.get('website') and bank.get('website') not in ('0', '', None):
                existing['website'] = bank['website']
        for key in keys:
            identities[key] = index
    return output
