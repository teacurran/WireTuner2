#!/usr/bin/env bash
# Help Book render (BASIC-007; docs/spec/building.adoc, "Help Book").
#
# Renders the user guide (docs/guide, no `spec` attribute -- the same render as `make docs-guide`)
# into one HTML file per page, <slug>.html, and checks that every page the Help panel's catalog
# (client/WTApp/Help/HelpCatalog.swift) names has one.  The app build copies the folder into the
# bundle's Resources/HelpBook (the "Help Book" build phase in client/project.yml), where
# HelpCatalog.bookURL finds it; without it the panel shows pages generated from the catalog.
#
#     tools/help/help-book.sh                 # -> client/build/HelpBook (`make help-book`)
#     tools/help/help-book.sh OUT_DIR
#
# Offline: the stylesheet is embedded, and web fonts and font icons are off, so the pages load
# nothing remote.
# Needs the Ruby asciidoctor CLI (`gem install asciidoctor`), as `make docs-check` does.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
out="${1:-$root/client/build/HelpBook}"
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac

command -v asciidoctor >/dev/null || { echo "help-book: asciidoctor not found (gem install asciidoctor)" >&2; exit 1; }

staging="$(mktemp -d "${TMPDIR:-/tmp}/help-book.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

asciidoctor --failure-level WARN -B "$root/docs" -a audience=guide -a webfonts! -a icons! -a nofooter \
  -D "$staging" "$root/docs/guide"/*.adoc

missing=0
while IFS= read -r slug; do
  if [ ! -s "$staging/$slug.html" ]; then
    echo "help-book: no page for catalog slug '$slug'" >&2
    missing=1
  fi
done < <(sed -n 's/.*slug: "\([^"]*\)".*/\1/p' "$root/client/WTApp/Help/HelpCatalog.swift" | sort -u)
[ "$missing" -eq 0 ] || exit 1

rm -rf "$out"
mkdir -p "$(dirname "$out")"
mv "$staging" "$out"
trap - EXIT
chmod 755 "$out"
echo "help-book: $(find "$out" -name '*.html' | wc -l | tr -d ' ') pages in $out"
