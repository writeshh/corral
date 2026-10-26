# How Corral works

This document describes the parts of Corral and how a request reaches PHP.

## Request flow

```
browser
  │  blog.internal
  ▼
/etc/resolver/internal ──► dnsmasq (127.0.0.1:53535) ──► 127.0.0.2
  │
  ▼  127.0.0.2:80 or :443
pf redirect ──► nginx (127.0.0.1:8180 or :8543)
  │
  ▼  unix socket run/php<version>.sock
php-fpm (one pool for each PHP version)
```

## Components

### DNS

macOS reads `/etc/resolver/internal` for each `.internal` lookup.
The file sends these lookups to dnsmasq on port 53535.
dnsmasq answers `127.0.0.2` for each `.internal` name, subdomains included.
dnsmasq runs as your user. A high port does not need root.

### Ports 80 and 443

Ports below 1024 need root on macOS.
Corral does not run nginx as root.
A LaunchDaemon runs one time at boot, and it does these steps:

1. It adds the `127.0.0.2` alias to the loopback interface.
2. It loads a pf rule in the `com.apple/corral` anchor.
3. The rule redirects `127.0.0.2:80` to `127.0.0.1:8180`.
4. The rule redirects `127.0.0.2:443` to `127.0.0.1:8543`.

Root never reads a file that your user can write.

### nginx

nginx runs as your user.
Corral writes one `nginx.conf` file with one server block for each site.
A request for an unknown host gets a 404 response.
After a change, Corral tests the configuration and reloads nginx.

### Bundled binaries

`scripts/build-deps.sh` compiles nginx and dnsmasq from source.
The script checks the SHA-256 checksum of each source archive.
nginx links OpenSSL, PCRE2, and zlib statically.
The binaries need only the macOS system libraries.
`bundle.sh` copies the binaries into `Corral.app/Contents/Resources/bin/`.

Corral looks for each binary in this order:

1. The `CORRAL_NGINX` or `CORRAL_DNSMASQ` environment variable
2. `Corral.app/Contents/Resources/bin/`
3. Homebrew

### PHP-FPM

`corral php:install` downloads static PHP builds from static-php-cli into `php/<version>/`.
Corral also finds Homebrew PHP in `/opt/homebrew/opt/php` and `/opt/homebrew/opt/php@X.Y`.
If both sources have the same version, Corral uses its own build.
Each version that a site uses gets its own PHP-FPM process and socket.
The global version is the newest installed version, unless you set a different one with `corral use`.

Corral writes small shell scripts to `bin/`:

- `php` runs the global version.
- `php84`, `php85`, and so on run a specific version.
- `corral` is a link to the Corral binary.

The scripts give the `php.ini` file of each static build to PHP.

### HTTPS

Corral uses `/usr/bin/openssl` to create a local CA.
`corral secure` signs a certificate for `site.internal` and `*.site.internal`.
Site certificates are valid for 397 days. macOS rejects longer validity periods.
The first `corral secure` adds the CA to your login keychain.

## Coexistence with Laravel Herd

Herd uses `.test` and `127.0.0.1`.
Corral uses `.internal` and `127.0.0.2`.
Both tools can run at the same time.

## Source layout

| File | Contents |
|---|---|
| `Sources/Corral/Core.swift` | Sites, configuration files, processes, TLS, and system installation |
| `Sources/Corral/CLI.swift` | Command-line interface |
| `Sources/Corral/MenuBar.swift` | Menu bar app |
| `Sources/Corral/main.swift` | Entry point. With arguments, it runs the CLI. Without arguments, it starts the menu bar app. |
| `Tests/CorralTests/` | Tests |
| `bundle.sh` | Builds `Corral.app` |
| `scripts/build-deps.sh` | Builds nginx and dnsmasq from source into `.deps/` |
