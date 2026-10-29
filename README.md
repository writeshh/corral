# Corral

Corral is a local PHP development environment for macOS.
It serves each project folder at its own domain, for example `http://blog.internal`.
Corral is a menu bar app and a command-line tool in one binary.

Corral does not collect telemetry.
Corral connects to the internet only when you install a PHP version.

## Features

- Serve every subfolder of a "parked" folder as `<folder>.internal`.
- Link a single folder to a domain name.
- Serve sites over HTTPS with certificates from a local certificate authority (CA).
- Use one global PHP version, or pin a different version to a site.
- Answer subdomains, for example `api.blog.internal`.
- Control everything from the menu bar or from the `corral` command.
- Include nginx and dnsmasq. Install PHP with one command.
- Run next to Laravel Herd without conflicts.

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

3. Add the commands to your path. Add this line to `~/.zshrc`, then open a new terminal:

   ```sh
   export PATH="$HOME/Library/Application Support/Corral/bin:$PATH"
   ```

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
| `corral park [dir]` | Serve each subfolder of `dir` as `<folder>.internal`. |
| `corral forget [dir]` | Stop serving the subfolders of `dir`. |
| `corral link [name]` | Serve the current folder as `<name>.internal`. |
| `corral unlink [name]` | Remove a linked site. |
| `corral proxy <name> <url>` | Serve a development server as `<name>.internal`. |
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
| `corral import:herd` | Copy the parked folders, links, secured sites, and global PHP version from Laravel Herd. |
| `corral uninstall` | Remove the system configuration. |

If you do not give a site name, Corral uses the site in the current folder.

## PHP

`corral php:install` downloads a static PHP build that Corral builds itself.
The builds come from the `php-builds` release of this repository.
Corral checks the SHA-256 checksum of each download. If the checksum is not correct, Corral does not install the build.

The builds use [static-php-cli](https://static-php.dev), the same tool that Laravel Herd uses. They include these extensions:

bcmath, bz2, calendar, ctype, curl, dom, exif, fileinfo, filter, ftp, gd (with FreeType, JPEG, and WebP), gmp, iconv, igbinary, intl, mbregex, mbstring, mysqli, mysqlnd, opcache, openssl, pcntl, pdo, pdo_mysql, pdo_pgsql, pdo_sqlite, pgsql, phar, posix, readline, redis, session, shmop, simplexml, soap, sockets, sodium, sqlite3, sysvmsg, sysvsem, sysvshm, tokenizer, xml, xmlreader, xmlwriter, xsl, zip, zlib.

The builds do not include imagick, imap, ldap, mongodb, sqlsrv, or Xdebug.
If you need one of these extensions, install PHP with Homebrew, for example `brew install php@8.4`.
Corral also finds Homebrew PHP versions. A version that Corral installed has priority over the Homebrew version.

Each PHP version that Corral installed has a `php.ini` file in `~/Library/Application Support/Corral/php/<version>/`.
Corral keeps your changes to this file when you update the version.
Run `corral restart` after a change.

## Menu bar app

Click the Corral icon in the menu bar to open the panel. The panel shows:

- The state of nginx, dnsmasq, and each PHP-FPM version, with a Start or Stop button
- A list of all sites. Click a site to open it in the browser.
- Site actions: copy the URL, show the folder in Finder, serve over HTTPS, and select the PHP version
- The global PHP version, and a menu to install more versions
- Errors and setup steps, directly in the panel

Right-click a site, or hold the pointer over it and click the "..." button, to show the site actions.

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
Multisite with subdomains also works, because each site answers `*.<site>.internal`.

## Use Corral next to Laravel Herd

Each site has two names: `<site>.internal` and `<site>.test`.
The `.internal` names always go to Corral.
The `.test` names go to Herd, until you run `corral takeover`.

Sites that you moved from Herd often keep their `.test` URL, for example in the WordPress `siteurl` or in `APP_URL` in `.env`.
These sites redirect to `.test`. To open them with Corral, send `.test` to Corral:

1. Quit Herd. Corral does not take `.test` while Herd runs, because Herd takes it back.
2. Send `.test` to Corral. macOS asks for your administrator password:

   ```sh
   corral takeover
   ```

3. For sites that use `https://`, run `corral secure <site>` one time.

To use Herd again:

1. Give `.test` back to Herd. Corral restores the resolver file of Herd from its backup:

   ```sh
   corral handback
   ```

2. Start Herd.

To copy your Herd setup to Corral, run:

```sh
corral import:herd
```

The command copies these settings. It reads the Herd files and does not change them.

- Parked folders
- Links, for example aliases such as `rfsudev`
- Secured sites. Corral makes its own certificates for these sites. The first certificate asks you to trust the Corral CA.
- The global PHP version. If the version is not installed, Corral downloads it.

You can run the command again. It adds only the settings that Corral does not have.

`corral status` shows which tool gets `.test`. The menu bar app has the same switch in the "..." menu.
`corral uninstall` also gives `.test` back to Herd.

Herd and Corral do not use the same IP addresses or ports, so both can run at the same time.
Only the `.test` names can go to one tool at a time.

## Development servers and portless

A proxy site sends requests for `<name>.internal` to a development server, for example Next.js or Vite.
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

Then open `http://shop.internal`.
For `.localhost` URLs, Corral connects to `127.0.0.1` and sends the original name.
portless needs the name to select the app.

## Site settings

To change the settings of one site, add a `.corral.json` file to the site folder:

```json
{
  "root": "dist",
  "nginx": "add_header X-Frame-Options DENY;"
}
```

| Key | Effect |
|---|---|
| `root` | The document root, relative to the site folder |
| `nginx` | Extra nginx directives for the server block of the site |

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

You can change the domain suffix with the `tld` key in `config.json`.
After a change, run `corral uninstall` and `corral install` again.

These environment variables change the defaults:

| Variable | Effect |
|---|---|
| `CORRAL_HOME` | Use a different state folder. Keep the path short. Socket paths must be shorter than 104 bytes. |
| `CORRAL_NGINX` | Use a different nginx binary. |
| `CORRAL_DNSMASQ` | Use a different dnsmasq binary. |
| `HOMEBREW_PREFIX` | Look for Homebrew PHP in a different folder. The default is `/opt/homebrew`. |

## Uninstall

1. Stop the services and remove the system configuration:

   ```sh
   corral uninstall
   ```

2. Remove the local CA from the login keychain. Use the Keychain Access app and search for "Corral Local CA".
3. Delete `~/Library/Application Support/Corral`.
4. Delete `Corral.app`.
5. Remove the Corral line from `~/.zshrc`.

## Limitations

- Corral does not include Composer or Node.js.
- Corral has special rules for WordPress only. Use `.corral.json` for frameworks such as Magento.
- Corral does not manage databases or mail.

## Documentation

- [How Corral works](docs/architecture.md)
- [Contributing](CONTRIBUTING.md)
- [Changelog](CHANGELOG.md)

## License

Corral is available under the [MIT License](LICENSE).

`Corral.app` includes nginx, OpenSSL, PCRE2, zlib, and dnsmasq.
Their licenses are in `Corral.app/Contents/Resources/licenses/`.
dnsmasq is GPL software. Its source code is in the same folder.
