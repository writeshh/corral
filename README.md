# Corral

Corral is a local PHP development environment for macOS.
It serves each project folder at its own domain, for example `http://blog.test`.
Corral is a menu bar app and a command-line tool in one binary.

Corral does not collect telemetry.
Corral connects to the internet only when you install a PHP version.

## Features

- Serve every subfolder of a "parked" folder as `<folder>.test`.
- Link a single folder to a domain name.
- Serve sites over HTTPS with certificates from a local certificate authority (CA).
- Use one global PHP version, or pin a different version to a site.
- Answer subdomains, for example `api.blog.test`.
- Control everything from the menu bar or from the `corral` command.
- Include nginx and dnsmasq. Install PHP with one command.
- Move from Laravel Herd in one step, or run next to Herd.
- Change PHP and PHP-FPM settings in a settings window.
- See `dump()` output, logs, and caught mail in the Insights window. Herd has these features only in Herd Pro.
- Open at login, and restart a service that stops.

## Requirements

- macOS 14 or later
- Apple silicon
- Xcode or the Xcode Command Line Tools, to build Corral

## Installation

1. Build the app. The first build compiles nginx and dnsmasq from source. This takes approximately one minute.

   ```sh
   ./bundle.sh
   ```

2. Install PHP. This step also adds the `corral` and `php` commands to `~/Library/Application Support/Corral/bin`.

   ```sh
   ./Corral.app/Contents/MacOS/Corral php:install 8.5
   ```

3. Open a new terminal. Corral adds this line to the end of `~/.zshrc` when it starts:

   ```sh
   export PATH="$HOME/Library/Application Support/Corral/bin:$PATH"
   ```

   The line comes after the Herd and Homebrew lines, so `php` runs Corral's build.
   Corral moves an older Corral line to the end and keeps the first original file as `~/.zshrc.corral.bak`.

4. Configure macOS networking. Corral asks for your administrator password one time:

   ```sh
   corral install
   ```

5. Start the services:

   ```sh
   corral start
   ```

6. Open `Corral.app` to show the menu bar icon.

Corral creates the folder `~/Corral` on first launch.
Each subfolder of `~/Corral` becomes a site.

## Usage

| Command | Effect |
|---|---|
| `corral park [dir]` | Serve each subfolder of `dir` as `<folder>.test`. |
| `corral forget [dir]` | Stop serving the subfolders of `dir`. |
| `corral link [name]` | Serve the current folder as `<name>.test`. |
| `corral unlink [name]` | Remove a linked site. |
| `corral proxy <name> <url>` | Serve a development server as `<name>.test`. |
| `corral unproxy <name>` | Remove a proxy site. |
| `corral sites` | List all sites with their URL, PHP version, and document root. |
| `corral secure [site]` | Serve a site over HTTPS. |
| `corral unsecure [site]` | Serve a site over HTTP. |
| `corral secured` | List secured sites with the expiry date of each certificate. |
| `corral use <version>` | Set the global PHP version, for example `8.4`. |
| `corral isolate <version> [site]` | Pin a PHP version to one site. |
| `corral unisolate [site]` | Use the global PHP version for a site again. |
| `corral php:list` | List the installed PHP versions. |
| `corral php:install <version>` | Download and install a PHP version, for example `8.4`. |
| `corral php:uninstall <version>` | Remove a PHP version that Corral installed. |
| `corral open [site]` | Open a site in the browser. |
| `corral start` | Start nginx, dnsmasq, and PHP-FPM. |
| `corral stop` | Stop all services. |
| `corral restart` | Stop and start all services. |
| `corral status` | Show the state of each service. |
| `corral trust` | Add the local CA to your login keychain. |
| `corral install` | Configure DNS and ports 80 and 443. |
| `corral takeover` | Send `.test` to Corral in place of Laravel Herd. |
| `corral handback` | Give `.test` back to Laravel Herd. |
| `corral migrate:herd` | Move from Laravel Herd. Add `--dry-run` to see the changes first, or `--undo` to give `.test` back to Herd. |
| `corral import:herd` | Copy the settings from Laravel Herd only. This is the first part of `migrate:herd`. |
| `corral uninstall` | Remove the system configuration. |

If you do not give a site name, Corral uses the site in the current folder.

## PHP

`corral php:install` downloads a static PHP build that Corral builds itself.
The builds come from the `php-builds` release of this repository.
Corral checks the SHA-256 checksum of each download. If the checksum is not correct, Corral does not install the build.

The builds use [static-php-cli](https://static-php.dev), the same tool that Laravel Herd uses. They include these extensions:

bcmath, bz2, calendar, ctype, curl, dom, exif, fileinfo, filter, ftp, gd (with FreeType, JPEG, and WebP), gmp, iconv, igbinary, intl, mbregex, mbstring, mysqli, mysqlnd, opcache, openssl, pcntl, pdo, pdo_mysql, pdo_pgsql, pdo_sqlite, pgsql, phar, posix, readline, redis, session, shmop, simplexml, soap, sockets, sodium, sqlite3, sysvmsg, sysvsem, sysvshm, tokenizer, xml, xmlreader, xmlwriter, xsl, zip, zlib.

The builds do not include imagick, imap, ldap, mongodb, sqlsrv, or Xdebug.
Corral uses only its own builds. It ignores Homebrew PHP, Herd PHP, and other PHP installs.
To make `php` in a terminal run Corral's build, put Corral's `bin` folder first in `PATH` (see the install steps).

Each PHP version that Corral installed has a `php.ini` file in `~/Library/Application Support/Corral/php/<version>/`.
Corral keeps your changes to this file when you update the version.
Run `corral restart` after a change.

Settings > PHP shows the common `php.ini` values and the PHP-FPM settings of each version:

- `memory_limit`, the maximum upload size, `max_execution_time`, `max_input_vars`, `display_errors`, `error_reporting`, `date.timezone`, OPcache, and `output_buffering`
- The process manager, the maximum number of processes, the request timeout, and the slow log

Corral checks the values with PHP and with `php-fpm -t` before it saves them.
If a value is not valid, Corral shows the PHP message and changes nothing.
Then Corral reloads PHP-FPM. Requests that run at that time can finish.

## Menu bar app

Click the Corral icon in the menu bar to open the panel. The panel shows:

- The state of nginx, dnsmasq, and each PHP-FPM version, with a Start or Stop button
- A list of all sites. Click a site to open it in the browser.
- Site actions: copy the URL, show the folder in Finder, serve over HTTPS, and select the PHP version
- The global PHP version, and a menu to install more versions
- Errors and setup steps, directly in the panel

Right-click a site, or hold the pointer over it and click the "..." button, to show the site actions.

The "..." menu at the bottom of the panel opens these windows:

- **Settings** (⌘,): open at login, domains, `.test` and Herd, PHP versions and settings, parked folders, links, proxies, certificates, and licences.
- **Insights** (⌘I): dumps, logs, and mail. See [Insights](#insights).

### Background service

When you start the services, Corral remembers it.
Then the app starts the services again when it opens, for example after a restart of the Mac.
The app also checks the services every 15 seconds and starts a service that stopped. The panel shows each restart.
`corral stop` turns this off until the next `corral start`.
To open Corral at login, turn on Settings > General > "Open Corral at login".

## Insights

Insights shows information from your sites. All of it stays on your Mac.

- **Dumps**: turn on "Send dump() to Corral". Then `dump()` and `dd()` in Laravel and Symfony sites show in Insights, not in the page. Corral uses the server mode of Symfony VarDumper on port 9912. Insights keeps the newest 1000 dumps.
- **Logs**: the Laravel logs in `storage/logs`, the WordPress `wp-content/debug.log`, and the nginx and PHP-FPM logs. Insights reads the file again every 2 seconds.
- **Mail**: turn on "Catch mail on 127.0.0.1:2525". Corral receives each message that a site sends with SMTP to this address, and keeps the newest 1000. Click a message to preview it. For a Laravel site, click "Send Mail to Corral" in the site menu. Corral then changes the `MAIL_` values in `.env`, and keeps the original file as `.env.corral.bak`.

Insights does not show database queries.

## Document root

Corral selects the document root in this order:

1. The `root` value in the `.corral.json` file of the site
2. The `public` folder, for Laravel and Symfony
3. The `web` folder, for Craft CMS, Drupal, and Bedrock
4. The site folder

Corral sends requests for missing files to `index.php`.
This works for most PHP frameworks.

## WordPress

Corral finds WordPress when the document root contains `wp-load.php` or `wp-config.php`.
For WordPress sites, Corral adds the nginx rules for multisite in subdirectories.
Multisite with subdomains also works, because each site answers `*.<site>.test`.

## Move from Laravel Herd

To move all your Herd sites to Corral, run:

```sh
corral migrate:herd --dry-run
corral migrate:herd
```

The first command shows the changes and changes nothing.
The second command does these steps. It asks before it quits Herd or removes the Herd login item.

1. It copies the parked folders and links.
2. It makes Corral certificates for the sites that Herd serves over HTTPS. The first certificate asks you to trust the Corral CA.
3. It copies the global PHP version, the PHP version of each site, and the proxies. It downloads each PHP version that is missing.
4. It copies the `php.ini` values of Herd into the PHP builds of Corral. Lines that work only in Herd stay out.
5. It quits Herd, and it can remove Herd from your login items.
6. It sends `.test` to Corral, starts the services, and opens each site.
7. It shows each site that does not work, with the likely cause. For example: a missing database, a wrong database password, or missing Composer packages.

The menu bar app shows the same steps when it finds Herd. The "..." menu also has "Move from Herd…".
Corral reads the Herd files and does not change them. Corral does not manage Node.js versions.

To use Herd again, run this command, then start Herd:

```sh
corral migrate:herd --undo
```

### Use Corral next to Laravel Herd

New installations use `.test`, like Herd. Only one tool can get `.test` at a time.
To run both tools, give Corral a second TLD in Settings > General, for example `internal`.
Each site then also answers `<site>.internal`, and these names always go to Corral.

`corral takeover` sends `.test` to Corral, and `corral handback` gives it back to Herd.
Quit Herd first, because Herd takes `.test` back while it runs.
`corral status` shows which tool gets `.test`.
Herd and Corral do not use the same IP addresses or ports, so both can run at the same time.

A `config.json` from an earlier Corral build keeps `.internal` as the main TLD, with `.test` as the second TLD.

## Development servers and portless

A proxy site sends requests for `<name>.test` to a development server, for example Next.js or Vite.
WebSocket connections also go through the proxy, so hot reload works.
You can use `corral secure <name>` to serve a proxy site over HTTPS.

```sh
corral proxy shop http://127.0.0.1:3000
```

[portless](https://github.com/vercel-labs/portless) gives each app a name such as `shop.localhost`.
If Laravel Herd uses ports 80 and 443, portless must use a different port, for example 1355.
Corral can serve the same app without a port:

```sh
corral proxy shop https://shop.localhost:1355
```

Then open `http://shop.test`.
If Herd has `.test`, give Corral a second TLD, for example `internal`, and open `http://shop.internal`.
For `.localhost` URLs, Corral connects to `127.0.0.1` and sends the original name.
portless needs the name to select the app.

## Site settings

To change the settings of one site, add a `.corral.json` file to the site folder:

```json
{
  "root": "dist",
  "nginx": "add_header X-Frame-Options DENY;",
  "domains": ["shop.local"],
  "php": { "memory_limit": "2048M" }
}
```

| Key | Effect |
|---|---|
| `root` | The document root, relative to the site folder |
| `nginx` | Extra nginx directives for the server block of the site |
| `domains` | More names for the site. Run `corral install` after you add a new TLD. |
| `php` | `php.ini` values for this site only. The site gets its own small PHP-FPM pool. |

Run `corral restart` after a change.
If the file is not valid JSON, `corral start` shows an error.

## Configuration

Corral keeps its state in `~/Library/Application Support/Corral`:

| Path | Contents |
|---|---|
| `config.json` | Parked folders, links, secured sites, and PHP versions |
| `conf/` | Generated nginx and PHP-FPM configuration |
| `run/` | Process IDs and PHP-FPM sockets |
| `logs/` | nginx and PHP-FPM logs |
| `certs/` | Local CA and site certificates |
| `php/` | PHP versions that Corral installed |
| `bin/` | `php` (global version) and `php84`-style commands for each version |
| `mail/` | Mail that Corral caught, as `.eml` files |

To change the TLD, use Settings > General. The main TLD is in the URLs.
Each extra TLD gives every site one more name.
Corral then updates `/etc/resolver` and asks for your administrator password.
Certificates get the new names the next time the services start.

These environment variables change the defaults:

| Variable | Effect |
|---|---|
| `CORRAL_HOME` | Use a different state folder. Keep the path short. Socket paths must be shorter than 104 bytes. |
| `CORRAL_NGINX` | Use a different nginx binary. |
| `CORRAL_DNSMASQ` | Use a different dnsmasq binary. |
| `HOMEBREW_PREFIX` | Look for Homebrew nginx and dnsmasq in a different folder. The default is `/opt/homebrew`. |

## Uninstall

1. Stop the services and remove the system configuration:

   ```sh
   corral uninstall
   ```

2. Remove the local CA from the login keychain. Use the Keychain Access app and search for "Corral Local CA".
3. Delete `~/Library/Application Support/Corral`.
4. Delete `Corral.app`.
5. `corral uninstall` removes the Corral line from `~/.zshrc`. Remove it yourself if you skip that step.

## Limitations

- Corral does not include Composer or Node.js.
- Corral has special rules for WordPress only. Use `.corral.json` for frameworks such as Magento.
- Corral does not manage databases.
- Insights does not show database queries.
- The PHP builds do not include Xdebug, so Corral has no debug pool yet.

## Documentation

- [How Corral works](docs/architecture.md)
- [Contributing](CONTRIBUTING.md)
- [Changelog](CHANGELOG.md)

## License

Corral is available under the [MIT License](LICENSE).

`Corral.app` includes nginx, OpenSSL, PCRE2, zlib, and dnsmasq.
Their licenses are in `Corral.app/Contents/Resources/licenses/`.
dnsmasq is GPL software. Its source code is in the same folder.
