#!/bin/sh
# Builds nginx and dnsmasq from source for Corral.app, and downloads Composer and WP-CLI.
# nginx links OpenSSL, PCRE2, and zlib statically, so the binaries need only macOS.
# Output: .deps/bin/{nginx,dnsmasq}, .deps/phar/{composer,wp-cli}.phar, and .deps/licenses/
set -eu
cd "$(dirname "$0")/.."

NGINX=1.30.6;   NGINX_SHA=3cf46f5ed7504d460125866b7bea99fb357f31d887e2e63b35503310e9b8b6c8
OPENSSL=3.6.5;  OPENSSL_SHA=a2157c2830efdec3788939b00c9b0638306d3f0bbb76dc4832ee503bb397df98
PCRE2=10.49;    PCRE2_SHA=929f0b20e62879252a15886b06c89f1edef61a363cbd5826fb041080a5e557ae
ZLIB=1.3.2;     ZLIB_SHA=bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16
DNSMASQ=2.93;   DNSMASQ_SHA=cc967771abdafeb43d10db18932d6b59fd4bed2c69c22acf8cb96aff6920d55f
COMPOSER=2.11.1; COMPOSER_SHA=6f1b891e1d4927d62740276c540fb490e47689e19e102c49e8da849794882f8c
COMPOSER_LICENSE_SHA=7855ac293067aebe7e51afdd23b9dea54b8be24187dbecc9b9142581c37f596c
WPCLI=2.12.0;   WPCLI_SHA=ce34ddd838f7351d6759068d09793f26755463b4a4610a5a5c0a97b68220d85c
WPCLI_LICENSE_SHA=9d94b972f0ea32ceb45bce0ab5229e421eaa3933fd07178d3256c13bae000ae5

OUT="$PWD/.deps"
SRC="$OUT/src"
JOBS=$(sysctl -n hw.ncpu)
export MACOSX_DEPLOYMENT_TARGET=14.0
mkdir -p "$SRC" "$OUT/bin" "$OUT/phar" "$OUT/licenses"

# fetch <url> <sha256>: download once, verify, and unpack into $SRC.
fetch() {
    file="$SRC/$(basename "$1")"
    [ -f "$file" ] || curl -fsSL "$1" -o "$file"
    echo "$2  $file" | shasum -a 256 -c - >/dev/null || { echo "Checksum mismatch: $file" >&2; rm -f "$file"; exit 1; }
    tar xzf "$file" -C "$SRC"
}

# get <url> <sha256> <destination>: download once, verify, and copy to the destination.
get() {
    file="$SRC/$(basename "$3")"
    [ -f "$file" ] || curl -fsSL "$1" -o "$file"
    echo "$2  $file" | shasum -a 256 -c - >/dev/null || { echo "Checksum mismatch: $file" >&2; rm -f "$file"; exit 1; }
    cp "$file" "$3"
}

fetch "https://nginx.org/download/nginx-$NGINX.tar.gz" "$NGINX_SHA"
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL/openssl-$OPENSSL.tar.gz" "$OPENSSL_SHA"
fetch "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2/pcre2-$PCRE2.tar.gz" "$PCRE2_SHA"
fetch "https://github.com/madler/zlib/releases/download/v$ZLIB/zlib-$ZLIB.tar.gz" "$ZLIB_SHA"
fetch "https://thekelleys.org.uk/dnsmasq/dnsmasq-$DNSMASQ.tar.gz" "$DNSMASQ_SHA"

(
    cd "$SRC/nginx-$NGINX"
    ./configure \
        --prefix=/usr/local/corral \
        --with-http_ssl_module --with-http_v2_module \
        --with-pcre="$SRC/pcre2-$PCRE2" --with-pcre-jit \
        --with-zlib="$SRC/zlib-$ZLIB" \
        --with-openssl="$SRC/openssl-$OPENSSL" --with-openssl-opt="no-shared no-tests no-docs" \
        --without-http_uwsgi_module --without-http_scgi_module --without-http_memcached_module \
        --with-cc-opt="-O2" >/dev/null
    make -j"$JOBS" >/dev/null
    cp objs/nginx "$OUT/bin/nginx"
)

(
    cd "$SRC/dnsmasq-$DNSMASQ"
    make -j"$JOBS" COPTS="-O2" >/dev/null
    cp src/dnsmasq "$OUT/bin/dnsmasq"
)

# Composer and WP-CLI are PHP archives. The shims in bin/ run them with the global PHP.
get "https://getcomposer.org/download/$COMPOSER/composer.phar" "$COMPOSER_SHA" "$OUT/phar/composer.phar"
get "https://github.com/wp-cli/wp-cli/releases/download/v$WPCLI/wp-cli-$WPCLI.phar" "$WPCLI_SHA" "$OUT/phar/wp-cli.phar"
get "https://raw.githubusercontent.com/composer/composer/$COMPOSER/LICENSE" "$COMPOSER_LICENSE_SHA" "$OUT/licenses/composer.txt"
get "https://raw.githubusercontent.com/wp-cli/wp-cli/v$WPCLI/LICENSE" "$WPCLI_LICENSE_SHA" "$OUT/licenses/wp-cli.txt"

# Licence texts. dnsmasq is GPL, so the exact source tarball ships next to the binary.
cp "$SRC/nginx-$NGINX/LICENSE" "$OUT/licenses/nginx.txt"
cp "$SRC/openssl-$OPENSSL/LICENSE.txt" "$OUT/licenses/openssl.txt"
cp "$SRC/pcre2-$PCRE2/LICENCE.md" "$OUT/licenses/pcre2.txt"
cp "$SRC/zlib-$ZLIB/LICENSE" "$OUT/licenses/zlib.txt"
cp "$SRC/dnsmasq-$DNSMASQ/COPYING" "$OUT/licenses/dnsmasq.txt"
cp "$SRC/dnsmasq-$DNSMASQ.tar.gz" "$OUT/licenses/"

echo "Built $OUT/bin/nginx and $OUT/bin/dnsmasq, and fetched Composer and WP-CLI"
