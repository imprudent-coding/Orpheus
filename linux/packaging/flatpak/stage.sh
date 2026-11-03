#!/usr/bin/env bash
set -euo pipefail

# Fills linux/packaging/flatpak/stage/ with everything the manifest installs:
# the finished Flutter bundle plus the desktop entry, icon and metainfo named
# after the app id, which is what flatpak-builder exports. Build with
#   flatpak-builder --user --install --force-clean build-dir \
#     linux/packaging/flatpak/com.github.imprudentcoding.orpheus.yml

BUNDLE_DIR="${1:?usage: stage.sh <bundle-dir> <version>}"
VERSION="${2:?}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGING_DIR="$(dirname "$SCRIPT_DIR")"
STAGE="$SCRIPT_DIR/stage"

rm -rf "$STAGE"
mkdir -p "$STAGE/bundle"
cp -a "$BUNDLE_DIR/." "$STAGE/bundle/"

sed -e '/^X-AppImage-Version=/d' \
    -e 's/^Icon=orpheus$/Icon=com.github.imprudentcoding.orpheus/' \
  "$PACKAGING_DIR/com.github.imprudentcoding.orpheus.desktop" > "$STAGE/com.github.imprudentcoding.orpheus.desktop"

sed -e "s|@VERSION@|$VERSION|" -e "s|@DATE@|$(date -u +%Y-%m-%d)|" \
  "$SCRIPT_DIR/com.github.imprudentcoding.orpheus.metainfo.xml" > "$STAGE/com.github.imprudentcoding.orpheus.metainfo.xml"

cp "$PACKAGING_DIR/jellybox.png" "$STAGE/com.github.imprudentcoding.orpheus.png"

cat > "$STAGE/orpheus" <<'EOF'
#!/bin/sh
exec /app/lib/orpheus/orpheus "$@"
EOF
chmod 755 "$STAGE/orpheus"

echo "Staged $(du -sh "$STAGE" | cut -f1) into $STAGE"
