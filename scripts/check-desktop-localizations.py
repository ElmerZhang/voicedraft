#!/usr/bin/env python3
"""Validate the desktop table, including keys selected by settings navigation."""
from pathlib import Path
import json
import re

root = Path(__file__).resolve().parents[1]
resources = root / 'Sources/VoiceDraftCore/Resources'

def read(code):
    source = (resources / f'{code}.lproj/Desktop.strings').read_text()
    pairs = re.findall(r'("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*")\s*;', source)
    values = {json.loads(key): json.loads(value) for key, value in pairs}
    assert len(values) == len(pairs), f'Duplicate keys: {code}'
    assert all(values.values()), f'Empty value: {code}'
    return values

base = read('en')
for code in ['zh-Hans', 'zh-Hant', 'ja', 'ko', 'de', 'fr', 'es']:
    assert read(code).keys() == base.keys(), f'Mismatched desktop keys: {code}'
used = {'Personalization', 'Settings', 'About', 'Help'}
for path in (root / 'Sources').rglob('*.swift'):
    used.update(re.findall(r'\bD\("([^"\n]+)"\)', path.read_text()))
assert not used - base.keys(), f'Missing desktop messages: {used - base.keys()}'
print(f'Validated {len(base)} desktop messages in 8 languages.')
