#!/usr/bin/env python3
"""Append missing L() keys to every Localizable.strings from translation tables.

Usage: tools/add-strings.py map.json [map2.json ...]

Each map is either {key: value} (one language) or {key: {lang: value}}.
Pass --lang CODE before a map to say which language it holds. Files are
UTF-16 LE with BOM, matching what Xcode and the existing bundles use.
Keys already present are never overwritten, so re-running is safe.
"""
import json, re, sys, pathlib

SPEC = re.compile(r'%(?:\d+\$)?[@dD@]')

def specs(s):
    return SPEC.findall(s)

def escape(s):
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')

def load_strings(path):
    text = path.read_bytes().decode('utf-16')
    keys = {}
    for m in re.finditer(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$',
                         text, re.M):
        raw = m.group(1).replace('\\"', '"').replace('\\\\', '\\')
        keys[raw] = m.group(2)
    return text, keys

def main(argv):
    maps = []
    lang = None
    for a in argv:
        if a.startswith('--lang='):
            lang = a.split('=', 1)[1]
            continue
        data = json.loads(pathlib.Path(a).read_text(encoding='utf-8'))
        if not data:
            continue
        first = next(iter(data.values()))
        if isinstance(first, dict):
            for code in first:
                maps.append((code, {k: v[code] for k, v in data.items()}))
        else:
            if not lang:
                raise SystemExit(f'{a}: pass --lang=CODE for a flat map')
            maps.append((lang, data))
            lang = None

    root = pathlib.Path(__file__).resolve().parent.parent
    total = 0
    for code, table in maps:
        path = root / 'Resources' / f'{code}.lproj' / 'Localizable.strings'
        if not path.exists():
            print(f'skip {code}: no bundle at {path}', file=sys.stderr)
            continue
        text, have = load_strings(path)
        added = []
        for key, value in table.items():
            if key in have:
                continue
            if not value:
                print(f'{code}: empty translation for {key!r}', file=sys.stderr)
                continue
            if specs(key) != specs(value):
                print(f'{code}: placeholder mismatch for {key!r}: {specs(key)} vs {specs(value)}',
                      file=sys.stderr)
                continue
            added.append((key, value))
        if not added:
            print(f'{code}: nothing to add')
            continue
        body = text
        if not body.endswith('\n'):
            body += '\n'
        body += '\n/* Added for keys that shipped after the first translation pass. */\n'
        for key, value in added:
            body += f'"{escape(key)}" = "{escape(value)}";\n'
        path.write_bytes(body.encode('utf-16'))
        total += len(added)
        print(f'{code}: added {len(added)}')
    print(f'total {total} entries')

if __name__ == '__main__':
    main(sys.argv[1:])
