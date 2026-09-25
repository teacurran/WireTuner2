#!/usr/bin/env python3
"""Help catalog generator (BASIC-007; docs/spec/building.adoc, "Help catalog").

The app's Help panel searches and shows the user guide from a generated Swift file,
client/WTApp/Help/HelpCatalog.swift.  This script writes it from docs/guide: for every guide
page (a `= Title` and a `:page-slug:`) its slug, title, `:page-group:`, a summary (the first
paragraph of its included body), its `==` section headings and its 40 most frequent words, all
read from the guide text only (everything from a page's `ifdef::spec[]` on is left out).

    tools/help/help-catalog.py            # rewrite the Swift file (`make help-catalog`)
    tools/help/help-catalog.py --check    # exit 1 if the committed file differs (`make help-catalog-check`)
    tools/help/help-catalog.py --root DIR # a checkout other than the one holding this script

The output is deterministic: pages in file-name order, headings in document order, keywords by
count with ties in first-seen order, no timestamps -- so the check can compare bytes.  Edit a
guide page, run `make help-catalog`, and commit the Swift beside the page.
"""
import argparse
import collections
import os
import re
import sys

OUTPUT = 'client/WTApp/Help/HelpCatalog.swift'
STOP = set("""that this with from your have they them their then than when what which while where there these those into only also each
other some such more most very will would could should about after before over under between through being been were does done
make makes made just like even much many here must text uses used using page pages""".split())


def clean(line):
    line = re.sub(r'xref:[^\[]*\[([^\]]*)\]', r'\1', line)
    line = re.sub(r'(kbd|menu|btn):([^\[]*)\[([^\]]*)\]', lambda m: (m.group(2) + ' ' + m.group(3)).strip(), line)
    line = re.sub(r'\{product\}', 'WireTuner', line)
    line = re.sub(r'[*_`]', '', line)
    return line.strip()


def swift(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


def read(path):
    with open(path, encoding='utf-8') as handle:
        return handle.read()


def page(root, text):
    """(slug, title, group, summary, headings, keywords) of one guide page, or None."""
    title = re.search(r'^= (.+)$', text, re.M)
    slug = re.search(r'^:page-slug: (.+)$', text, re.M)
    group = re.search(r'^:page-group: (.+)$', text, re.M)
    if not title or not slug:
        return None
    body = ''
    for include in re.findall(r'^include::(_includes/[^\[]+)\[\]', text, re.M):
        path = os.path.join(root, 'docs', include)
        if os.path.exists(path):
            body += read(path).split('ifdef::spec[]')[0]
    headings, summary, words, paragraph = [], '', collections.Counter(), []
    for raw in body.splitlines():
        line = raw.strip()
        if line.startswith('== '):
            headings.append(clean(line[3:]))
            continue
        if not summary:
            if line and not line.startswith(('//', '[', '|', ':', 'include::', '.', '=', 'image::', 'NOTE', '*', '-')):
                paragraph.append(clean(line))
            elif paragraph:
                summary = ' '.join(paragraph)
        for word in re.findall(r'[A-Za-z][A-Za-z-]{3,}', clean(line).lower()):
            if word not in STOP:
                words[word] += 1
    if not summary:
        summary = ' '.join(paragraph)
    keywords = [w for w, _ in words.most_common(40)]
    return (slug.group(1).strip(), clean(title.group(1)), group.group(1).strip() if group else '', summary, headings, keywords)


def catalog(root):
    guide = os.path.join(root, 'docs/guide')
    pages = []
    for name in sorted(os.listdir(guide)):
        if name.endswith('.adoc'):
            entry = page(root, read(os.path.join(guide, name)))
            if entry:
                pages.append(entry)
    out = ['// Generated from docs/guide by tools/help/help-catalog.py (`make help-catalog`); do not edit.',
           '', '/// The bundled guide as the Help panel searches and shows it (BASIC-007).', 'extension HelpCatalog {',
           '    static let pages: [HelpPage] = [']
    for slug, title, group, summary, headings, keywords in pages:
        out.append('        HelpPage(slug: %s, title: %s, group: %s, summary: %s,' % (swift(slug), swift(title), swift(group), swift(summary)))
        out.append('                 headings: [%s],' % ', '.join(swift(h) for h in headings))
        out.append('                 keywords: [%s]),' % ', '.join(swift(k) for k in keywords))
    out += ['    ]', '}', '']
    return '\n'.join(out), len(pages)


def main():
    parser = argparse.ArgumentParser(description='Write the Help panel catalog from docs/guide (BASIC-007).')
    parser.add_argument('--root', default=os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')))
    parser.add_argument('--check', action='store_true', help='fail if the committed catalog differs instead of writing it')
    args = parser.parse_args()
    text, count = catalog(args.root)
    target = os.path.join(args.root, OUTPUT)
    if args.check:
        current = read(target) if os.path.exists(target) else None
        if current != text:
            state = 'is missing' if current is None else 'is out of date with docs/guide'
            print('%s %s: run `make help-catalog` and commit it' % (OUTPUT, state), file=sys.stderr)
            return 1
        print('%s matches docs/guide (%d pages)' % (OUTPUT, count))
        return 0
    with open(target, 'w', encoding='utf-8', newline='\n') as handle:
        handle.write(text)
    print('%s: %d pages' % (OUTPUT, count))
    return 0


if __name__ == '__main__':
    sys.exit(main())
