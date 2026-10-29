# How Corral works

This document describes the parts of Corral and how a request reaches PHP.

## Request flow

```
browser
  │  blog.test
  ▼
/etc/resolver/test ──► dnsmasq (127.0.0.1:53535) ──► 127.0.0.2
  │
  ▼  127.0.0.2:80 or :443
pf redirect ──► nginx (127.0.0.1:8180 or :8543)
  │
  ▼  unix socket run/php<version>.sock
php-fpm (one pool for each PHP version)
```

## Components

### DNS

macOS reads `/etc/resolver/test` for each `.test` lookup.
The file sends these lookups to dnsmasq on port 53535.
dnsmasq answers `127.0.0.2` for each `.test` name, subdomains included.
dnsmasq runs as your user. A high port does not need root.

The main TLD (`tld` in `config.json`) is `test`. Extra TLDs (`aliases`) and the `domains` of each site add more names.
Corral writes the names to `conf/dnsmasq.conf`. dnsmasq reads the file only at start, so Corral restarts dnsmasq when the names change.
`corral install` writes one resolver file for each TLD in use.

Herd also uses `.test`. When `.test` is the main TLD, `corral install` takes it over.
When `.test` is only an extra TLD, `corral takeover` and `corral handback` move it between Herd and Corral.
`corral takeover` copies the Herd version of `/etc/resolver/test` to `/Library/Application Support/Corral/herd-resolver-test`.
Then it writes the Corral version.
`corral handback` moves the copy back.
The backup folder belongs to root.

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
Each server block sends requests for missing files to `index.php`.
For WordPress sites, the block also contains the rewrite rules for multisite in subdirectories.
The `nginx` value from `.corral.json` goes into the server block of that site.
After a change, Corral tests the configuration and reloads nginx.
When "Send dump() to Corral" is on, each server block also sets `VAR_DUMPER_FORMAT=server` for PHP.

### Proxy sites

A proxy site has a server block with `proxy_pass` and no PHP.
nginx sends the WebSocket `Upgrade` and `Connection` headers to the development server.
For a `*.localhost` upstream, nginx connects to `127.0.0.1`.
nginx sends the original name in the `Host` header and as the TLS server name (SNI).
Name-based routers such as portless need this name.

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

`corral php:install` reads `manifest.json` from the `php-builds` release of this repository.
It downloads the archive for the version, checks its SHA-256 checksum, and unpacks it into `php/<version>/`.
`.github/workflows/php.yml` makes these archives with `scripts/build-php.sh`, which uses static-php-cli.
The builds do not read `/usr/local/etc/php/conf.d`. Corral gives each version its `php.ini` file with `-c`.
Corral uses only these builds. It ignores Homebrew PHP and other PHP installs.
Each version that a site uses gets its own PHP-FPM process and socket.
The pool settings of each version are in `fpm` in `config.json`. Default values are not stored.
A site with `php` values in `.corral.json` gets its own small pool and socket.
Corral does not use `fastcgi_param PHP_VALUE`, because the value stays set in the worker and goes into the next request of another site.
The socket name of a site pool is a hash of the site name, because macOS limits socket paths to 104 bytes.
When the configuration of a version changes, Corral reloads its PHP-FPM with `SIGUSR2`.
The global version is the newest installed version, unless you set a different one with `corral use`.

Corral writes small shell scripts to `bin/`:

- `php` runs the global version.
- `php84`, `php85`, and so on run a specific version.
- `corral` is a link to the Corral binary.

The scripts give the `php.ini` file of each static build to PHP.

PHP accepts a `php.ini` file that is not valid, with exit code 0, and only prints warnings.
So the settings window runs `php -c <new file> -r ''` and treats any output as an error.

### Supervision

`corral start` creates `run/autostart`, and `corral stop` removes it.
While the file exists, the menu bar app starts each service that is down, at launch and every 15 seconds.
The app is the only supervisor. Corral does not use a LaunchAgent, because launchd and the app would then manage the same processes.
If a PHP-FPM master process stops, its workers can keep the socket open. Before Corral starts PHP-FPM, it stops the processes that hold the socket (`lsof -t`).

### HTTPS

Corral uses `/usr/bin/openssl` to create a local CA.
`corral secure` signs a certificate for `site.test` and `*.site.test`, and for each other name of the site.
Site certificates are valid for 397 days. macOS rejects longer validity periods.
The first `corral secure` adds the CA to your login keychain.
`corral start` makes a new certificate for each secured site whose certificate is missing or expires within 30 days.
Corral reads the expiry dates with the macOS Security framework, so the check takes less than a second.
Corral also makes a new certificate when the names of a site change. It compares the names with the `.ext` file next to the certificate.
Herd and Valet do not renew site certificates.

### Insights

Symfony VarDumper sends each dump to `127.0.0.1:9912` as one line: base64 of `serialize([$data, $context])`.
Swift cannot read serialized PHP objects.
So Corral runs `conf/dump-decoder.php` with the global PHP version. The script loads only the VarDumper classes from the `vendor` folder of the site, not the autoloader of the project.

The mail server is a small SMTP server on `127.0.0.1:2525`. It accepts each message and each login.
The SMTP user name is the inbox name, as in Herd.
Each message is an `.eml` file in `mail/`. Quick Look shows the message, so Corral reads only the headers.

### Moving from Herd

`importHerd` reads these Herd files and never writes them:

| File | Contents |
|---|---|
| `config/valet/config.json` | Parked folders and the TLD |
| `config/valet/Sites/` | Links |
| `config/valet/Certificates/` | Secured sites |
| `config/valet/Nginx/<site>.test` | Proxies (`proxy_pass`) and site PHP versions (`herdNN.sock` or `ISOLATED_PHP_VERSION`) |
| `config/php/<NN>/php.ini` | `php.ini` values. Corral leaves out `extension`, `auto_prepend_file`, the CA bundle, and paths into Herd. |
| `herd.sock` | The global PHP version |

A dry run changes the configuration in memory, and then restores it.
After the import, `finishHerdMove` quits Herd, takes over `.test`, starts the services, and requests each site with `curl --connect-to`.
It reads the response and the new lines of the PHP-FPM log to name the likely cause of an error.

## Coexistence with Laravel Herd

Herd uses `127.0.0.1`. Corral uses `127.0.0.2`.
Both tools can run at the same time. Only one tool can get `.test` at a time.

## Source layout

| File | Contents |
|---|---|
| `Sources/Corral/Core.swift` | Sites, configuration files, processes, TLS, and system installation |
| `Sources/Corral/CLI.swift` | Command-line interface |
| `Sources/Corral/MenuBar.swift` | Menu bar app, panel, and supervision |
| `Sources/Corral/Settings.swift` | Settings window |
| `Sources/Corral/Insights.swift` | Insights window: dumps and logs |
| `Sources/Corral/Mail.swift` | SMTP server and the Mail view |
| `Sources/Corral/main.swift` | Entry point. With arguments, it runs the CLI. Without arguments, it starts the menu bar app. |
| `Tests/CorralTests/` | Tests |
| `bundle.sh` | Builds `Corral.app` |
| `scripts/build-deps.sh` | Builds nginx and dnsmasq from source into `.deps/` |
