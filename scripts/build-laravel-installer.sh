#!/bin/sh
# Builds the Laravel installer as one phar with Box, the way Herd ships its `laravel` command.
# Usage: scripts/build-laravel-installer.sh [version]   (default: the newest laravel/installer release)
# Needs PHP 8.2 or newer in PATH, or in $PHP, with the phar extension.
# Output: .deps/laravel-dist/laravel.phar and manifest.json (version, file, SHA-256)
# The installer source comes from the GitHub tag over HTTPS. GitHub publishes no checksum for it,
# so the SHA-256 of the built phar in manifest.json is what the app checks.
set -eu
cd "$(dirname "$0")/.."
ROOT="$PWD"

BOX=4.7.1; BOX_SHA=aedabb38bad96a90868603f118956c3faa662b545c06be66df1b145aba703c0a
PHP="${PHP:-php}"

# CI runners share IP addresses, so the anonymous API rate limit is often used up. Send GH_TOKEN when it is set.
AUTH=${GH_TOKEN:+"Authorization: Bearer $GH_TOKEN"}
VERSION="${1:-$(curl -fsSL ${AUTH:+-H "$AUTH"} https://api.github.com/repos/laravel/installer/releases/latest | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))')}"
case "$VERSION" in [0-9]*.[0-9]*.[0-9]*) ;; *) echo "Bad version: $VERSION" >&2; exit 1 ;; esac

./scripts/fetch-tools.sh >/dev/null
WORK="$PWD/.deps/laravel-build"
DIST="$PWD/.deps/laravel-dist"
rm -rf "$WORK/installer-$VERSION" "$DIST"
mkdir -p "$WORK" "$DIST"

if [ ! -f "$WORK/box.phar" ]; then
    curl -fsSL -o "$WORK/box.phar" "https://github.com/box-project/box/releases/download/$BOX/box.phar"
fi
echo "$BOX_SHA  $WORK/box.phar" | shasum -a 256 -c - >/dev/null || { echo "Checksum mismatch: box.phar" >&2; rm -f "$WORK/box.phar"; exit 1; }

curl -fsSL "https://github.com/laravel/installer/archive/refs/tags/v$VERSION.tar.gz" | tar xz -C "$WORK"
cd "$WORK/installer-$VERSION"
"$PHP" "$ROOT/.deps/phar/composer.phar" install --no-dev --no-scripts --classmap-authoritative --no-interaction --no-progress
cp "$ROOT/scripts/laravel-installer/box.json" box.json
"$PHP" -d phar.readonly=0 "$WORK/box.phar" compile --no-interaction

# The phar must run and report the version it was built from.
"$PHP" laravel.phar --version | grep -q "$VERSION" || { echo "laravel.phar does not report $VERSION" >&2; exit 1; }
cp laravel.phar "$DIST/laravel.phar"
SHA=$(shasum -a 256 "$DIST/laravel.phar" | cut -d' ' -f1)
printf '{"laravel": {"version": "%s", "file": "laravel.phar", "sha256": "%s"}}\n' "$VERSION" "$SHA" > "$DIST/manifest.json"
echo "Built $DIST/laravel.phar ($VERSION, $SHA)"
