#!/bin/sh
# Builds static PHP (cli + fpm) for Corral with static-php-cli, the same tool Herd uses.
# Usage: scripts/build-php.sh 8.4
# Output: .deps/php-dist/php-<version>-macos-<arch>.tar.gz and a .sha256 file next to it.
set -eu
cd "$(dirname "$0")/.."

MINOR="${1:?usage: scripts/build-php.sh <minor version, for example 8.4>}"
SPC_VERSION=2.8.5
SPC_SHA=acf2f25d56d0cbf8e65aa82e5054fef555f7be7c5c38046c6e0819f266d83225  # spc-macos-aarch64.tar.gz

# Herd's set, without imagick, imap, ldap, mongodb, sqlsrv and FFI (large, rarely needed).
# mysqli is the one that matters: WordPress needs it, and static-php-cli's "common" builds lack it.
EXTS="bcmath,bz2,calendar,ctype,curl,dom,exif,fileinfo,filter,ftp,gd,gmp,iconv,igbinary,intl,mbregex,mbstring,mysqli,mysqlnd,opcache,openssl,pcntl,pdo,pdo_mysql,pdo_pgsql,pdo_sqlite,pgsql,phar,posix,readline,redis,session,shmop,simplexml,soap,sockets,sodium,sqlite3,sysvmsg,sysvsem,sysvshm,tokenizer,xml,xmlreader,xmlwriter,xsl,zip,zlib"
LIBS="freetype,libjpeg,libwebp"

# Xdebug is a shared extension (xdebug.so next to php). Corral loads it only in the debug pool.
# Herd does the same. 3.5.x supports PHP 8.0 to 8.5.
XDEBUG_URL=https://xdebug.org/files/xdebug-3.5.3.tgz
XDEBUG_SHA=f073de91bea046106abf4d6071c963ea71e58571df6ce58948ceca89d121cb2d

# --prefer-pre-built takes most libraries from static-php-cli's pre-built release (February 2026).
# Two of them were old there and missed security fixes: OpenSSL 3.6.2 and SQLite 3.45.2.
# Corral builds them from these sources. OpenSSL is the 3.5 LTS line, the same as nginx in build-deps.sh.
OPENSSL=3.5.9; OPENSSL_SHA=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
SQLITE=3.54.1; SQLITE_SHA=926ef8d3eab93fbf6e06011901273eec076b25594a4e1cdadd50c987f4f6d64e
OPENSSL_URL=https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL/openssl-$OPENSSL.tar.gz
SQLITE_URL=https://www.sqlite.org/2026/sqlite-autoconf-3540100.tar.gz # the file name encodes $SQLITE

ARCH=$(uname -m | sed 's/arm64/aarch64/')
[ "$ARCH" = aarch64 ] || { echo "Only Apple silicon builds are set up." >&2; exit 1; }

WORK="$PWD/.deps/php-build"
DIST="$PWD/.deps/php-dist"
mkdir -p "$WORK" "$DIST"
cd "$WORK"

if [ ! -x spc ]; then
    curl -fsSL -o spc.tar.gz "https://github.com/crazywhalecc/static-php-cli/releases/download/$SPC_VERSION/spc-macos-aarch64.tar.gz"
    echo "$SPC_SHA  spc.tar.gz" | shasum -a 256 -c - >/dev/null
    tar xzf spc.tar.gz && rm spc.tar.gz
fi

# A build for another version leaves its sources behind, and static-php-cli would reuse them.
# The download cache stays, except for the PHP source. The cache holds one PHP version, and it would
# also hide new patch releases from the weekly build.
rm -rf source buildroot

# Installs missing build tools with Homebrew (for example bison and re2c).
./spc doctor --auto-fix --no-interaction
# A cached pre-built package wins over a source, so remove the pre-built packages of the pinned libraries.
./spc del-download openssl,sqlite --pre-built-only
./spc download --with-php="$MINOR" --for-extensions="$EXTS,xdebug" --for-libs="$LIBS" --prefer-pre-built --retry=3 \
    --ignore-cache-sources=php-src --custom-url="xdebug:$XDEBUG_URL" \
    --custom-url="openssl:$OPENSSL_URL" --custom-url="sqlite:$SQLITE_URL"
# verify <url> <sha256>: the custom URL downloads keep the file name of the URL.
verify() {
    echo "$2  downloads/$(basename "$1")" | shasum -a 256 -c - >/dev/null || { echo "Checksum mismatch: $(basename "$1")" >&2; exit 1; }
}
verify "$XDEBUG_URL" "$XDEBUG_SHA"
verify "$OPENSSL_URL" "$OPENSSL_SHA"
verify "$SQLITE_URL" "$SQLITE_SHA"
# static-php-cli passes --with-pic to the SQLite configure script, and SQLite 3.48 and later reject it.
# So the script builds SQLite here. static-php-cli finds libsqlite3.a in buildroot and skips its own build.
mkdir -p source
tar xzf "downloads/$(basename "$SQLITE_URL")" -C source
(
    cd source/sqlite-autoconf-*
    CFLAGS="-Os -fPIC -DSQLITE_ENABLE_COLUMN_METADATA=1" ./configure --prefix="$WORK/buildroot" --disable-shared --enable-static >/dev/null
    make -j"$(sysctl -n hw.ncpu)" install >/dev/null
)
# The bcmath code in PHP 8.1 uses old K&R C. Newer compilers default to C23 and reject it.
if [ "$MINOR" = "8.1" ]; then
    export SPC_DEFAULT_C_FLAGS="-fpic -fpie -std=gnu17"
    export SPC_CMD_VAR_PHP_MAKE_EXTRA_CFLAGS="-g -fstack-protector-strong -fpic -fpie -Werror=unknown-warning-option --target=arm64-apple-darwin -Os -std=gnu17"
fi
# Corral passes php.ini with -c. An empty scan folder stops PHP from reading /usr/local/etc/php/conf.d.
./spc build "$EXTS" --build-shared=xdebug --with-libs="$LIBS" --build-cli --build-fpm \
    --with-config-file-path=/usr/local/etc/corral-php --with-config-file-scan-dir= --no-interaction

VERSION=$(buildroot/bin/php -n -r 'echo PHP_VERSION;')
case "$VERSION" in "$MINOR".*) ;; *) echo "Built $VERSION, expected $MINOR.x" >&2; exit 1 ;; esac
# The shared extension must load into the static binaries, or the build is not usable.
buildroot/bin/php -n -d zend_extension="$PWD/buildroot/modules/xdebug.so" -r 'exit(extension_loaded("xdebug") ? 0 : 1);' \
    || { echo "xdebug.so does not load." >&2; exit 1; }
# The binary must link the pinned libraries, not the pre-built ones.
FOUND=$(buildroot/bin/php -n -r 'echo OPENSSL_VERSION_TEXT, "|", SQLite3::version()["versionString"];')
case "$FOUND" in "OpenSSL $OPENSSL "*"|$SQLITE") ;; *) echo "Unexpected libraries: $FOUND" >&2; exit 1 ;; esac

STAGE=$(mktemp -d)
cp buildroot/bin/php buildroot/bin/php-fpm buildroot/modules/xdebug.so "$STAGE/"
NAME="php-$VERSION-macos-$ARCH.tar.gz"
tar czf "$DIST/$NAME" -C "$STAGE" php php-fpm xdebug.so
rm -rf "$STAGE"
(cd "$DIST" && shasum -a 256 "$NAME" > "$NAME.sha256")
echo "Built $DIST/$NAME"
