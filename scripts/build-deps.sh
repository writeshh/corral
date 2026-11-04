#!/bin/sh
# Builds nginx and dnsmasq from source for Corral.app.
# nginx links OpenSSL, PCRE2, and zlib statically, so the binaries need only macOS.
# Output: .deps/bin/{nginx,dnsmasq} and .deps/licenses/
set -eu
cd "$(dirname "$0")/.."

NGINX=1.30.6;   NGINX_SHA=3cf46f5ed7504d460125866b7bea99fb357f31d887e2e63b35503310e9b8b6c8
OPENSSL=3.6.5;  OPENSSL_SHA=a2157c2830efdec3788939b00c9b0638306d3f0bbb76dc4832ee503bb397df98
PCRE2=10.49;    PCRE2_SHA=929f0b20e62879252a15886b06c89f1edef61a363cbd5826fb041080a5e557ae
ZLIB=1.3.2;     ZLIB_SHA=bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16
DNSMASQ=2.93;   DNSMASQ_SHA=cc967771abdafeb43d10db18932d6b59fd4bed2c69c22acf8cb96aff6920d55f

OUT="$PWD/.deps"
SRC="$OUT/src"
JOBS=$(sysctl -n hw.ncpu)
export MACOSX_DEPLOYMENT_TARGET=14.0
mkdir -p "$SRC" "$OUT/bin" "$OUT/licenses"

# fetch <url> <sha256>: download once, verify, and unpack into $SRC.
fetch() {
    file="$SRC/$(basename "$1")"
    [ -f "$file" ] || curl -fsSL "$1" -o "$file"
    echo "$2  $file" | shasum -a 256 -c - >/dev/null || { echo "Checksum mismatch: $file" >&2; rm -f "$file"; exit 1; }
    tar xzf "$file" -C "$SRC"
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

# Licence texts. dnsmasq is GPL, so the exact source tarball ships next to the binary.
cp "$SRC/nginx-$NGINX/LICENSE" "$OUT/licenses/nginx.txt"
cp "$SRC/openssl-$OPENSSL/LICENSE.txt" "$OUT/licenses/openssl.txt"
cp "$SRC/pcre2-$PCRE2/LICENCE.md" "$OUT/licenses/pcre2.txt"
cp "$SRC/zlib-$ZLIB/LICENSE" "$OUT/licenses/zlib.txt"
cp "$SRC/dnsmasq-$DNSMASQ/COPYING" "$OUT/licenses/dnsmasq.txt"
cp "$SRC/dnsmasq-$DNSMASQ.tar.gz" "$OUT/licenses/"

echo "Built $OUT/bin/nginx and $OUT/bin/dnsmasq"
