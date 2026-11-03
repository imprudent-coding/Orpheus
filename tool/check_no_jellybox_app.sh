#!/usr/bin/env bash
# ORPHEUS: fails when a reference to jellybox.app (the JellyBox cloud, relay
# and tunnel services) appears in lib/ or packages/. Orpheus removed those
# services; a new hit after an upstream rebase means upstream added a code
# path that has to be removed again. NOTICE/README files are excluded because
# they may credit the original project.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

pattern='jellybox\.app'
hits="$(grep -rIn -i -E "$pattern" lib packages \
  --exclude-dir=.dart_tool --exclude-dir=build \
  --exclude='NOTICE*' --exclude='README*' || true)"

if [[ -n "$hits" ]]; then
  echo "Found references to jellybox.app in lib/ or packages/:" >&2
  echo "$hits" >&2
  echo "Orpheus does not use the JellyBox cloud, relay or tunnel services." >&2
  exit 1
fi
echo "No jellybox.app references in lib/ or packages/"
