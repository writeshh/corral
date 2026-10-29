# Changelog

All notable changes to this project are in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
The project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-29

### Added

- Menu bar app with service status, a site list, HTTPS toggles, and PHP version pickers.
- `corral` command-line interface.
- Parked folders and linked sites on the `.internal` domain, with subdomain support.
- HTTPS with a local certificate authority.
- Global PHP version and PHP versions for each site.
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
- Settings window (⌘,) with tabs for General, PHP, Sites, Certificates, and About. Sites lists parked folders, links, and proxies, with add and remove buttons.
- "Open Corral at login" switch. The app starts the services again if they ran before, and restarts a service that stops.
- Extra TLDs (`aliases` in `config.json`, Settings > General) and extra names for each site (`domains` in `.corral.json`).
- PHP and PHP-FPM settings for each version in Settings > PHP. Corral checks the values with PHP and `php-fpm -t` before it saves them.
- `php` values in `.corral.json` for one site. The site gets its own PHP-FPM pool.
- `corral migrate:herd` and "Move from Herd…" in the app: copy the Herd setup, quit Herd, take over `.test`, and check each site. `--dry-run` shows the changes first. `--undo` gives `.test` back.
- Insights window (⌘I) with dumps from `dump()` and `dd()`, site and service logs, and caught mail on `127.0.0.1:2525`.
- "Send Mail to Corral" in the menu of a Laravel site. It changes the `MAIL_` values in `.env` and keeps a backup.
- App icon: a hexagon "C" with an orange site, in a light and a dark version. The Dock icon follows the system appearance.
- The menu bar and the panel header show the app icon. The menu bar icon dims when the services stop.
- Corral shows in the Dock and in ⌘-Tab while a Corral window is open. "Show Corral in the Dock" keeps it there.
- Corral writes its `bin` folder to the end of `~/.zshrc`, so `php` in a terminal runs Corral's build. `corral uninstall` removes the line.
- Settings shows the full PHP version, for example 8.4.27. "Update to" shows only when a newer build exists.
- The panel groups sites by parked folder. Each group opens and closes.
- Insights colours dumps by token type and logs by level. A dump shows its request method and a link to its source file.

### Changed

- New installations use `.test` as the main TLD, like Herd. A `config.json` from an earlier build keeps `.internal`, with `.test` as the second TLD.
- `corral install` writes one resolver file for each TLD in use. `corral uninstall` removes each resolver file that points to Corral.
- `corral import:herd` also copies the PHP version of each site, proxies, and `php.ini` values.
- `corral php:install` uses Corral's own PHP builds, with a SHA-256 checksum check. The builds include mysqli, intl, and sodium, so WordPress works. `scripts/build-php.sh` and `.github/workflows/php.yml` make the builds.
- The menu bar app is now a panel with a site list, service status, inline errors, and an empty state. Slow work, such as a PHP download, runs in the background, so the panel does not freeze.
- Corral uses only its own PHP builds. It ignores Homebrew PHP and other PHP installs. A site on a Homebrew version uses the global version until you install Corral's build of that version.
- The app uses Corral orange as its accent colour. Errors, notices, and empty states have one shared look. The Insights tabs are in the window toolbar.

### Fixed

- PHP-FPM starts again after its master process stopped. Before, the old workers kept the socket and the start failed.
- The default `php.ini` for Corral's PHP builds uses the values of Laravel Herd: `memory_limit` 1024M, `max_execution_time` 600, and `output_buffering` 4096. Before, early deprecation notices could break redirects and hide the real HTTP status.
- A Herd resolver file for the same domain no longer counts as a Corral installation.
- `corral uninstall` removes only resolver files that point to Corral.
- Sites with `DB_HOST=localhost` find the MySQL socket of DBngin and Herd.
- Folder names keep their dots, as in Herd and Valet. `crm.pigment` is `crm.pigment.internal`.
- A `config.json` from an older version no longer resets the settings. Corral does not overwrite a `config.json` that is not valid.
- Dumps from sites with symfony/var-dumper 5.4 or 6.0 show in Insights. Before, PHP deprecation notices broke the decoder output.
- PHP updates read a fresh build list. Before, GitHub's cache could serve an old list, and the update said that no build existed.
- The menu bar panel shrinks after a banner closes, and the site list text is sharp.
- Port numbers show without a thousands separator, for example 2525.

[Unreleased]: https://github.com/writeshh/corral/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/writeshh/corral/releases/tag/v0.1.0
