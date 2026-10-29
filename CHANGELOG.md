# Changelog

All notable changes to this project are in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
The project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Menu bar app with service status, a site list, HTTPS toggles, and PHP version pickers.
- `corral` command-line interface.
- Parked folders and linked sites on the `.internal` domain, with subdomain support.
- HTTPS with a local certificate authority.
- Global PHP version and PHP versions for each site, from Homebrew.
- `corral install` and `corral uninstall` for DNS and ports 80 and 443. They use one administrator prompt.
- `bundle.sh` to build `Corral.app`.
- nginx and dnsmasq inside `Corral.app`, compiled from source by `scripts/build-deps.sh`. Homebrew is not necessary.
- `corral php:install` and `corral php:uninstall` for static PHP builds from static-php-cli.
- `php`, `php84`-style, and `corral` commands in `~/Library/Application Support/Corral/bin`.
- "Install PHP" menu in the menu bar app.
- WordPress detection with nginx rules for multisite in subdirectories.
- `web/` document root for Craft CMS, Drupal, and Bedrock.
- `.corral.json` site settings for the document root and extra nginx directives.
- `corral proxy` and `corral unproxy` for development servers, with WebSocket support. This includes portless apps on `*.localhost`.
- Each site also answers `<site>.test`. `corral takeover` sends `.test` to Corral, and `corral handback` gives it back to Laravel Herd. The menu bar app has the same switch.
- `corral import:herd` copies the parked folders, links, secured sites, and global PHP version from Laravel Herd.
- `corral start` renews site certificates that expire within 30 days. `corral secured` lists the expiry date of each certificate.

### Changed

- `corral php:install` uses Corral's own PHP builds, with a SHA-256 checksum check. The builds include mysqli, intl, and sodium, so WordPress works. `scripts/build-php.sh` and `.github/workflows/php.yml` make the builds.
- The menu bar app is now a panel with a site list, service status, inline errors, and an empty state. Slow work, such as a PHP download, runs in the background, so the panel does not freeze.

### Fixed

- The default `php.ini` for Corral's PHP builds uses the values of Laravel Herd: `memory_limit` 1024M, `max_execution_time` 600, and `output_buffering` 4096. Before, early deprecation notices could break redirects and hide the real HTTP status.
- A Herd resolver file for the same domain no longer counts as a Corral installation.
- `corral uninstall` removes only resolver files that point to Corral.
- Sites with `DB_HOST=localhost` find the MySQL socket of DBngin and Herd.
- Folder names keep their dots, as in Herd and Valet. `crm.pigment` is `crm.pigment.internal`.
- A `config.json` from an older version no longer resets the settings. Corral does not overwrite a `config.json` that is not valid.
