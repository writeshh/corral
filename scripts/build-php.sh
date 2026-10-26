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

# Installs missing build tools with Homebrew (for example bison and re2c).
./spc doctor --auto-fix --no-interaction
./spc download --with-php="$MINOR" --for-extensions="$EXTS" --for-libs="$LIBS" --prefer-pre-built --retry=3
# Corral passes php.ini with -c. An empty scan folder stops PHP from reading /usr/local/etc/php/conf.d.
./spc build "$EXTS" --with-libs="$LIBS" --build-cli --build-fpm \
    --with-config-file-path=/usr/local/etc/corral-php --with-config-file-scan-dir= --no-interaction

VERSION=$(buildroot/bin/php -n -r 'echo PHP_VERSION;')
case "$VERSION" in "$MINOR".*) ;; *) echo "Built $VERSION, expected $MINOR.x" >&2; exit 1 ;; esac

STAGE=$(mktemp -d)
cp buildroot/bin/php buildroot/bin/php-fpm "$STAGE/"
NAME="php-$VERSION-macos-$ARCH.tar.gz"
tar czf "$DIST/$NAME" -C "$STAGE" php php-fpm
rm -rf "$STAGE"
(cd "$DIST" && shasum -a 256 "$NAME" > "$NAME.sha256")
echo "Built $DIST/$NAME"
