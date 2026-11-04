#!/bin/sh
# Downloads Composer, WP-CLI, and the Laravel installer for Corral.app, and checks each SHA-256.
# Composer and WP-CLI have a pinned version here. The Laravel installer comes from the "tools" release
# of this repository, which .github/workflows/tools.yml fills (see scripts/build-laravel-installer.sh).
# Output: .deps/phar/{composer,wp-cli,laravel}.phar, .deps/phar/versions.json, and licence texts in .deps/licenses/
set -eu
cd "$(dirname "$0")/.."

COMPOSER=2.11.1; COMPOSER_SHA=6f1b891e1d4927d62740276c540fb490e47689e19e102c49e8da849794882f8c
COMPOSER_LICENSE_SHA=7855ac293067aebe7e51afdd23b9dea54b8be24187dbecc9b9142581c37f596c
WPCLI=2.12.0;   WPCLI_SHA=ce34ddd838f7351d6759068d09793f26755463b4a4610a5a5c0a97b68220d85c
WPCLI_LICENSE_SHA=9d94b972f0ea32ceb45bce0ab5229e421eaa3933fd07178d3256c13bae000ae5
TOOLS_URL="${CORRAL_TOOLS_URL:-https://github.com/writeshh/corral/releases/download/tools}"

OUT="$PWD/.deps"
SRC="$OUT/src"
mkdir -p "$SRC" "$OUT/phar" "$OUT/licenses"

# get <url> <sha256> <destination>: download once, verify, and copy to the destination.
get() {
    file="$SRC/$(basename "$3")"
    [ -f "$file" ] || curl -fsSL "$1" -o "$file"
    echo "$2  $file" | shasum -a 256 -c - >/dev/null || { echo "Checksum mismatch: $file" >&2; rm -f "$file"; exit 1; }
    cp "$file" "$3"
}

get "https://getcomposer.org/download/$COMPOSER/composer.phar" "$COMPOSER_SHA" "$OUT/phar/composer.phar"
get "https://github.com/wp-cli/wp-cli/releases/download/v$WPCLI/wp-cli-$WPCLI.phar" "$WPCLI_SHA" "$OUT/phar/wp-cli.phar"
get "https://raw.githubusercontent.com/composer/composer/$COMPOSER/LICENSE" "$COMPOSER_LICENSE_SHA" "$OUT/licenses/composer.txt"
get "https://raw.githubusercontent.com/wp-cli/wp-cli/v$WPCLI/LICENSE" "$WPCLI_LICENSE_SHA" "$OUT/licenses/wp-cli.txt"

# The Laravel installer is optional here: before the first run of the workflow there is no release.
# Without it the app still builds. Settings > Tools downloads it later.
LARAVEL=""
if curl -fsSL "$TOOLS_URL/manifest.json" -o "$SRC/tools-manifest.json" 2>/dev/null; then
    set -- $(python3 -c 'import json,sys; m=json.load(open(sys.argv[1]))["laravel"]; print(m["version"], m["sha256"], m["file"])' "$SRC/tools-manifest.json")
    rm -f "$SRC/laravel.phar"
    get "$TOOLS_URL/$3" "$2" "$OUT/phar/laravel.phar"
    LARAVEL="$1 $2"
else
    echo "No Laravel installer in the tools release yet. Corral.app is built without it." >&2
    rm -f "$OUT/phar/laravel.phar"
fi

python3 - "$COMPOSER $COMPOSER_SHA" "$WPCLI $WPCLI_SHA" "$LARAVEL" > "$OUT/phar/versions.json" <<'PY'
import json, sys
names = ["composer", "wp", "laravel"]
out = {}
for name, arg in zip(names, sys.argv[1:]):
    if arg.strip():
        version, sha = arg.split()
        out[name] = {"version": version, "sha256": sha}
print(json.dumps(out, indent=2, sort_keys=True))
PY
echo "Fetched the tools into $OUT/phar"
