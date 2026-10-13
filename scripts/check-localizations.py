#!/usr/bin/env python3
"""Check shipped localization parity and literal UI/error coverage; no dependencies."""
from pathlib import Path
import re

def literals(s):
    def string_end(i):
        start=i;i+=1
        while i<len(s):
            if s[i]=='"': return i+1
            if s[i]=='\\':
                if s[i+1:i+2]=='(':
                    i=paren_end(i+2)
                else: i+=2
            else:i+=1
        raise ValueError(s[start:start+50])
    def paren_end(i):
        depth=1
        while depth:
            if s[i]=='"':i=string_end(i)
            elif s[i]=='(':depth+=1;i+=1
            elif s[i]==')':depth-=1;i+=1
            else:i+=1
        return i
    i=0
    while i<len(s):
        if s.startswith('//',i):
            n=s.find('\n',i);i=n if n>=0 else len(s)
        elif s.startswith('"""',i):
            n=s.index('"""',i+3);i=n+3
        elif s[i]=='"':
            end=string_end(i);yield i,end,s[i+1:end-1];i=end
        else:i+=1


import json

def key(text):
 out='';i=0;n=0
 while i<len(text):
  if text.startswith('\\(',i):
   depth=1;i+=2
   while depth:
    if text[i]=='"':
     i+=1
     while text[i]!='"': i+=2 if text[i]=='\\' else 1
     i+=1
    elif text[i]=='(':depth+=1;i+=1
    elif text[i]==')':depth-=1;i+=1
    else:i+=1
   out+='{'+str(n)+'}';n+=1
  elif text[i]=='\\':
   out+=json.loads('"'+text[i:i+2]+'"');i+=2
  else:out+=text[i];i+=1
 return out


ROOT = Path(__file__).resolve().parents[1]
resources = ROOT / 'Sources/VoiceDraftCore/Resources'
codes = ['en', 'zh-Hans', 'zh-Hant', 'ja', 'ko', 'de', 'fr', 'es']
def read(path):
    pairs = re.findall(r'("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*")\s*;', path.read_text())
    values = {json.loads(k): json.loads(v) for k, v in pairs}
    assert len(values) == len(pairs), f'Duplicate keys in {path}'
    return values
base = read(resources / 'en.lproj/Localizable.strings')
slots = lambda s: sorted(re.findall(r'\{\d+\}|%\d*d', s))
for code in codes:
    values = read(resources / f'{code}.lproj/Localizable.strings')
    assert values.keys() == base.keys(), f'Mismatched keys in {code}: {set(base) ^ set(values)}'
    for k, v in values.items():
        assert v and slots(k) == slots(v), f'Invalid translation in {code}: {k}'
    assert read(resources / f'{code}.lproj/InfoPlist.strings')['NSMicrophoneUsageDescription']
used = set()
for path in (ROOT / 'Sources').rglob('*.swift'):
    source = path.read_text()
    for start, end, value in literals(source):
        prefix = source[max(0, start - 100):start]
        if re.search(r'(?:\bL|\.message)\(\s*$', prefix) or re.search(r'(?:\bstatus|\bsyncStatus|\bnotice)(?:: LocalizedMessage)?\s*=\s*$', prefix):
            if value: used.add(key(value))
        if path.name == 'Views.swift' and re.search(r'(?:Text|Button|Label|Picker|Toggle|SingleLineField|LabeledContent|DisclosureGroup|\.help|\.accessibilityLabel|\.confirmationDialog)\(\s*$', prefix):
            # Brand and expressions containing only data/separators do not need translation.
            if value != 'VoiceDraft' and not value.startswith(('\\(', '· ')):
                raise AssertionError(f'Unlocalized UI literal in {path.name}: {value}')
missing = used - base.keys()
assert not missing, f'Missing source messages: {sorted(missing)}'
print(f'Validated {len(base)} messages in {len(codes)} languages, placeholders, privacy text, and source coverage.')
