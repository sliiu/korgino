#!/usr/bin/env python3
"""Move named AppConfig functions out of Config.swift into an extension file.

One-off refactoring aid. Usage:
  tools/split-config.py <out.swift> <function> [<function> ...]

A moved function takes its doc comment and any attribute lines directly above
it. Blocks are delimited by brace pairing, not indentation, so one-line bodies
(`func f() -> Bool { x }`) work too.

`private` at type scope is file-scoped in Swift, so a helper that the main file
also calls becomes inaccessible once it moves. The script widens such accesses
one at a time as the compiler reports them; run it, build, then fix reported
`private` members by dropping the keyword in the new file.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONFIG = ROOT / 'Engine' / 'Config.swift'

FUNC = re.compile(r'^    (private |static |private static )?func ([a-zA-Z0-9_]+)')
LEADING = re.compile(r'^    (///|@|//)')


def blocks_of(lines):
    """name -> (first_line_including_doc_comment, last_line)."""
    start = next(i for i, l in enumerate(lines) if l.startswith('final class AppConfig'))
    found = {}
    i = start
    while i < len(lines):
        m = FUNC.match(lines[i])
        if not m:
            i += 1
            continue
        name = m.group(2)
        # Absorb the contiguous comment/attribute lines directly above.
        first = i
        while first - 1 > start and LEADING.match(lines[first - 1]):
            first -= 1
        depth = 0
        opened = False
        j = i
        while j < len(lines):
            depth += lines[j].count('{') - lines[j].count('}')
            if '{' in lines[j]:
                opened = True
            if opened and depth <= 0:
                break
            j += 1
        if j >= len(lines):
            raise SystemExit(f'{name}: block never closes')
        found[name] = (first, j)
        i = j + 1
    return found


def main(argv):
    if not argv:
        raise SystemExit(__doc__)
    out_path = ROOT / argv[0]
    names = argv[1:]
    lines = CONFIG.read_text(encoding='utf-8').splitlines()
    found = blocks_of(lines)
    missing = [n for n in names if n not in found]
    if missing:
        raise SystemExit(f'not found: {missing}')

    spans = sorted(found[n] for n in names)
    body = []
    for a, b in spans:
        body.extend(lines[a:b + 1])
        body.append('')
    out_path.write_text(
        'import Foundation\n\n'
        f'/// {out_path.stem[7:] if out_path.stem.startswith("Config+") else out_path.stem}: part of AppConfig.\n'
        'extension AppConfig {\n'
        + '\n'.join(body).rstrip() + '\n}\n',
        encoding='utf-8',
    )

    for a, b in reversed(spans):
        del lines[a:b + 1]
        while a < len(lines) and lines[a].strip() == '' and (a == 0 or lines[a - 1].strip() == ''):
            del lines[a]
    CONFIG.write_text('\n'.join(l.rstrip() for l in lines) + '\n', encoding='utf-8')
    print(f'{out_path.name}: moved {len(names)}; Config.swift now {len(lines)} lines')


if __name__ == '__main__':
    main(sys.argv[1:])
