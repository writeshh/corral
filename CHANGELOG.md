# Changelog

All notable changes to this project are in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
The project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The PHP builds include Xdebug 3.5.3 as a shared extension (`xdebug.so` next to `php`). PHP loads it only when `php.ini` asks for it.
- A debug pool for Xdebug. A second PHP-FPM for each PHP version loads Xdebug. nginx sends a request to it only with an `XDEBUG_SESSION` or `XDEBUG_TRIGGER` cookie or query argument. Normal requests run without Xdebug.
- Settings > PHP > Xdebug and `corral xdebug [on|off]` turn the pool on or off. They set the mode, client host, client port, and when a session starts.
- The panel shows each debug pool as `php <version> debug`, and Corral restarts a debug pool that stops.
- `corral run <command>` runs a development server on a free port and serves it at `https://<folder>.test` while it runs. `--name` and `--port` change the name and the port.
- `corral new <name>` creates a Laravel project with the bundled installer in the parked folder, serves it over HTTPS, and sets `APP_URL`. Corral adds `--no-boost` unless you pass `--boost`.
- `corral mail`, `mail:show`, `mail:links`, and `mail:clear` list, print, and delete the mail that Corral caught. `mail:links` undoes quoted-printable, so a wrapped link prints whole.
- `corral wp:import <dump>` and "Import Database…" in the site menu import a SQL dump (`.sql` or `.sql.gz`) into a WordPress site with `mysqli`, then replace the old address with `https://<site>.test` through `wp search-replace`.
- Insights > Queries, `corral queries [on|off]`, and `corral queries:list`: Laravel and WordPress sites record each SQL query with its time and caller. Insights marks slow queries and counts repeated ones.
- The Xdebug profiler: with `--profile on` (or the switch in Insights > Profiles or Settings), an `XDEBUG_PROFILE` cookie or query argument sends a request to the debug pool, which writes a cachegrind file to `profiles`. Insights > Profiles lists, opens, and deletes the files. `corral profile <url>` profiles one request. Corral deletes profiles after 7 days, and the oldest ones above 1 GB.
- Settings > Tools > New WordPress sites and `corral wp:defaults` set the admin user, password, email, locale, and table prefix that `wp:setup` and "Set Up WordPress…" use. The locale also selects the WordPress download and the site language.
- `corral uninstall:herd` and "Uninstall Herd…" in the panel remove Herd after a move, following Herd's own uninstall script. Herd.app and its folder go to the Trash. Herd Pro data and the Laravel Valet CA each need their own confirmation, and `/etc/resolver/test` stays when it points to Corral.
- Editor detection: while a program listens on the Xdebug client port on this Mac, every PHP request goes to the debug pool, with no cookie. The app checks every 2 seconds and says when this changes. `corral xdebug --detect on|off` and Settings > PHP > Xdebug turn it on or off.
- `corral uninstall:herd` moves Herd's nvm (Node.js versions and global npm packages) to `~/.nvm` and loads it from the shell file, so `node`, `npm`, and global CLIs keep working without Herd.
- Insights > Requests (before: Queries) also records outgoing HTTP calls for Laravel and WordPress, and cache and queue events for Laravel. Each request shows them in sections, with failed and slow HTTP calls marked, and cache events grouped by key.
- Proxy sites send a `localhost` origin to the `/_next` paths when the page comes from the site itself. Next.js hot reload then works on `.test` names without `allowedDevOrigins`.

### Changed

- "Check for Updates" in Settings > About shows its result next to the button: checking, up to date, or the new version with an "Update and Restart" button. A manual check no longer installs by itself. Before, the result showed only in the menu bar panel.
- After an automatic update, the panel says which version Corral updated to.
- Settings > About no longer shows the "Telemetry" row. Corral still sends no telemetry.

- `corral wp:setup`, `corral laravel:setup`, and the panel's setup actions create the database with Corral's PHP (`mysqli`). They no longer need the `mysql` client.

### Fixed

- Recording requests no longer causes a "Constant SAVEQUERIES already defined" warning in a WordPress site whose `wp-config.php` defines `SAVEQUERIES`. The site's own value counts.
- Section footers in Settings are aligned to the leading edge. The Settings window aligned multi-line footers to the right.
- Settings > General no longer shows the main TLD as an extra TLD. Corral drops an extra TLD that is the same as the main TLD, for example after the main TLD changed from `internal` to `test`.
- The menu bar app no longer changes `~/.zshrc` when it runs with a Corral home other than the default one (`CORRAL_HOME`, tests). Before, it put that home's `bin` folder first in `PATH`.
- The Insights window shows errors from its dumps and mail switches. Before, they showed only in the menu bar panel.
- The PHP build script uses the PHP version that it is asked for. Before, a cached source of another version was reused, and the weekly build did not pick up new patch releases.

## [0.5.0] - 2026-11-04

### Added

- `corral wp:setup [name]` sets up WordPress in the current folder: database, core files, `wp-config.php`, HTTPS, and debug settings.
- `corral laravel:setup [name] [--seed]` sets up a cloned Laravel project: Composer packages, `.env`, app key, database, migrations, npm build, and HTTPS.
- Corral.app includes Composer, WP-CLI, and the Laravel installer. The commands `composer`, `wp`, and `laravel` are in Corral's `bin` folder and run on the global PHP version.
- Settings > Tools and `corral tools:update` update these tools. Each download is checked against a SHA-256. `corral tools` shows the versions.
- A GitHub workflow builds the Laravel installer into one phar and publishes it to the `tools` release.
- The site menu in the panel has "Set Up WordPress…" and "Set Up Laravel…". They run the steps of `corral wp:setup` and `corral laravel:setup`.
- The panel and `corral sites` list the apps that portless serves, with their addresses.

## [0.4.0] - 2026-11-03

### Added

- Corral looks for a new release on GitHub when it starts and then once a day. It downloads the release, checks the SHA-256 checksum, replaces the app, and opens it again. Settings > About has a switch to turn off the automatic install, a "Check for Updates" button, and an "Update to" button.
- `corral update` installs the newest release.

### Fixed

- The `corral` command in a terminal finds the nginx and dnsmasq inside Corral.app. Before, it failed with "nginx not found" when it ran through the `bin/corral` link, and it could break that link.

## [0.3.1] - 2026-11-02

### Fixed

- A site address without a trailing slash, for example `https://shop.test/wp-admin`, redirects to the same host. Before, the redirect added the internal port 8543 or 8180, and the page did not load.

## [0.3.0] - 2026-11-02

### Added

- The Logs tab has a "Follow browser" button. It picks the site that your browser shows. It works with Safari, Chrome, Brave, Edge, Arc, Dia, and Vivaldi.
- The Logs tab has a search field for the site list. Return picks the first match.

### Fixed

- The Logs tab keeps its site, its file, and the Clear state after a switch to another tab. The site and file also stay after a restart.
- The Logs tab shows the newest line when a log opens.

## [0.2.0] - 2026-10-29

### Added

- The panel shows the progress of the site check after a move from Herd, for example "Checking sites 12/133".

### Changed

- The site check after a move from Herd requests the sites in parallel. With 133 sites, the check takes approximately 33 seconds, not several minutes.

### Fixed

- The site check after a move from Herd uses the browser address, 127.0.0.2. Before, a pf rule dropped the direct requests to nginx, and each site showed "no response".
- Only one menu bar app runs at a time. Before, `corral` without arguments in a terminal started a second app. Now it shows the help.

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

[Unreleased]: https://github.com/writeshh/corral/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/writeshh/corral/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/writeshh/corral/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/writeshh/corral/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/writeshh/corral/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/writeshh/corral/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/writeshh/corral/releases/tag/v0.1.0
