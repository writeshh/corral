# Corral

Corral is a local PHP development environment for macOS.
It serves each project folder at its own domain, for example `http://blog.test`.
Corral is a menu bar app and a command-line tool in one binary.

Corral does not collect telemetry.
Corral connects to the internet only to install a PHP version and to look for a new release of Corral on GitHub.

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
- Debug with Xdebug in a separate PHP-FPM pool. Normal requests run without Xdebug.
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
| `corral run [--name n] [--port p] <command>` | Run a development server and serve it at `https://<folder>.test` while it runs. |
| `corral sites` | List all sites with their URL, PHP version, and document root. Also lists portless apps. |
| `corral check` | Request every PHP site and show each site that does not work, with the likely cause, for example a missing database. |
| `corral secure [site]` | Serve a site over HTTPS. |
| `corral unsecure [site]` | Serve a site over HTTP. |
| `corral secured` | List secured sites with the expiry date of each certificate. |
| `corral use <version>` | Set the global PHP version, for example `8.4`. |
| `corral isolate <version> [site]` | Pin a PHP version to one site. |
| `corral unisolate [site]` | Use the global PHP version for a site again. |
| `corral php:list` | List the installed PHP versions. |
| `corral php:install <version>` | Download and install a PHP version, for example `8.4`. |
| `corral php:uninstall <version>` | Remove a PHP version that Corral installed. |
| `corral xdebug [on\|off]` | Turn the Xdebug debug pool on or off. See [Xdebug](#xdebug). |
| `corral wp:setup [name]` | Set up WordPress in the current folder. See [WordPress setup](#wordpress-setup). |
| `corral profile <url>` | Profile one request with Xdebug and print the cachegrind file. See [Profiler](#profiler). |
| `corral profiles` | List the profiler files. |
| `corral queries [on\|off]` | Record the SQL queries, HTTP calls, and cache and queue events of Laravel and WordPress requests. See [Insights](#insights). |
| `corral queries:list [n]` | Print what the newest `n` requests recorded. |
| `corral wp:defaults [options]` | Show or change the admin user, password, email, locale, and table prefix of `wp:setup`. |
| `corral wp:import <dump> [name]` | Import a SQL dump into a WordPress site and change its address to `<name>.test`. See [WordPress setup](#wordpress-setup). |
| `corral new <name> [options]` | Create a Laravel project in the parked folder and serve it over HTTPS. See [New Laravel projects](#new-laravel-projects). |
| `corral laravel:setup [name] [--seed]` | Set up a cloned Laravel project in the current folder. See [Laravel setup](#laravel-setup). |
| `corral mail [inbox]` | List the mail that Corral caught, newest first. See [Insights](#insights). |
| `corral mail:show [n]` | Print message `n` (1 is the newest) as a raw `.eml` file. |
| `corral mail:links [n]` | Print the links in message `n`, for example a link to verify an email address. |
| `corral mail:wait [inbox] [--timeout s]` | Wait for the next mail, for example in a test after a sign-up, and print it like `corral mail`. Without an inbox, any new mail counts. It fails after 60 seconds, or after `--timeout`. |
| `corral mail:attachments [n] [folder]` | Save the attachments of message `n` in a folder (the current folder by default). |
| `corral mail:use [name]` | Send the mail of a Laravel or WordPress site to Corral, like "Send Mail to Corral" in the panel. |
| `corral mail:clear` | Delete all caught mail. |
| `corral tools` | Show the versions of `composer`, `wp`, and `laravel`. See [Bundled tools](#bundled-tools). |
| `corral tools:update [name]` | Update `composer`, `wp`, or `laravel` (all by default). |
| `corral open [site]` | Open a site in the browser. |
| `corral start` | Start nginx, dnsmasq, and PHP-FPM. |
| `corral stop` | Stop all services. |
| `corral restart` | Stop and start all services. |
| `corral status` | Show the state of each service. |
| `corral trust` | Add the local CA to your login keychain. |
| `corral update` | Install the newest release from GitHub. |
| `corral install` | Configure DNS and ports 80 and 443. |
| `corral takeover` | Send `.test` to Corral in place of Laravel Herd. |
| `corral handback` | Give `.test` back to Laravel Herd. |
| `corral migrate:herd` | Move from Laravel Herd. Add `--dry-run` to see the changes first, or `--undo` to give `.test` back to Herd. |
| `corral uninstall:herd [--dry-run]` | Remove Herd after the move. Herd.app and its folder go to the Trash. See [Uninstall Herd](#uninstall-herd). |
| `corral import:herd` | Copy the settings from Laravel Herd only. This is the first part of `migrate:herd`. |
| `corral uninstall` | Remove the system configuration. |

If you do not give a site name, Corral uses the site in the current folder.

## Updates

Corral looks for a new release in the GitHub releases of this repository when it starts and then once a day.
Corral downloads `Corral.zip`, checks its SHA-256 checksum against the checksum of the release, replaces the app, and opens it again.
The services keep running during the update.
Settings > About has a switch to turn off the automatic install. Then the "Update to" button installs the release when you click it.
`corral update` does the same from a terminal. Quit and open Corral to use the new version.

## PHP

`corral php:install` downloads a static PHP build that Corral builds itself.
The builds come from the `php-builds` release of this repository.
Corral checks the SHA-256 checksum of each download. If the checksum is not correct, Corral does not install the build.

The builds use [static-php-cli](https://static-php.dev), the same tool that Laravel Herd uses. They include these extensions:

bcmath, bz2, calendar, ctype, curl, dom, exif, fileinfo, filter, ftp, gd (with FreeType, JPEG, and WebP), gmp, iconv, igbinary, intl, mbregex, mbstring, mysqli, mysqlnd, opcache, openssl, pcntl, pdo, pdo_mysql, pdo_pgsql, pdo_sqlite, pgsql, phar, posix, readline, redis, session, shmop, simplexml, soap, sockets, sodium, sqlite3, sysvmsg, sysvsem, sysvshm, tokenizer, xml, xmlreader, xmlwriter, xsl, zip, zlib.

The builds do not include imagick, imap, ldap, mongodb, sqlsrv, or FFI.

Each build also has Xdebug 3.5.3 as a shared extension (`xdebug.so` next to `php`). PHP does not load it unless `php.ini` or a command line option asks for it.
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

### Xdebug

Each PHP build has Xdebug, but PHP does not load it for normal requests.
Xdebug slows PHP down, and Corral keeps it out of the way.
Turn on the debug pool in Settings > PHP > Xdebug, or run `corral xdebug on`.
Then Corral starts a second PHP-FPM for each PHP version that is in use. Only this PHP-FPM loads Xdebug.

nginx sends a request to the debug pool when it has one of these:

- an `XDEBUG_SESSION` or `XDEBUG_TRIGGER` cookie
- an `XDEBUG_SESSION`, `XDEBUG_SESSION_START`, or `XDEBUG_TRIGGER` query argument

A browser extension for Xdebug sets the cookie. Other requests use the normal pool.

You do not need the cookie while your editor listens for Xdebug.
The menu bar app checks every 2 seconds whether a program listens on the client port (9003) on this Mac, for example PhpStorm after "Start Listening for PHP Debug Connections", or a VS Code debug session.
While one listens, every PHP request goes to the debug pool, and the panel says so. When the editor stops listening, requests use the normal pool again.
Turn this off in Settings > PHP > Xdebug, or with `corral xdebug --detect off`. Corral does not detect an editor on another computer (a client host other than `127.0.0.1`).
The debug pool reads the same `php.ini` as the normal pool.
It starts processes on demand, and it has no request time limit, because a session waits at a breakpoint.

Xdebug connects to your editor at `127.0.0.1` on port 9003. Start listening for debug connections in the editor.
Settings > PHP > Xdebug changes the mode (`debug,develop` by default), the client host, the client port,
and whether every request in the pool starts a session or only requests with `XDEBUG_TRIGGER`.
`corral xdebug` has the options `--mode`, `--host`, `--port`, `--start`, `--profile`, and `--detect`.
Corral restarts the debug pool after a change.
The panel shows the debug pool as `php 8.4 debug`, and Corral restarts it if it stops.

A PHP build from before Corral had Xdebug has no `xdebug.so`. Update the PHP version in Settings > PHP.

#### Profiler

Turn on the profiler in Insights > Profiles, in Settings > PHP > Xdebug, or with `corral xdebug on --profile on`.
The profiler runs in the debug pool, so this also turns on the debug pool.

- A request with an `XDEBUG_PROFILE` cookie or query argument goes to the debug pool, and Xdebug writes a cachegrind file for it. Add `?XDEBUG_PROFILE=1` to a URL, or run `corral profile <url>`.
- Each trigger starts only its own mode: `XDEBUG_SESSION` debugs, `XDEBUG_PROFILE` profiles, and `XDEBUG_TRIGGER` does both. While the profiler is on, the "start a session" setting is always `trigger`.
- The files go to `profiles` in Corral's folder. The name holds the time, the host, and the path, for example `cachegrind.out.1794246235.436050.shop_test__checkout`.
- Corral deletes profiles that are older than 7 days, and the oldest profiles when all of them use more than 1 GB.
- Insights > Profiles lists the files. "Open" uses the app that your Mac uses for the file. To read cachegrind files, install qcachegrind (`brew install qcachegrind`), or use PhpStorm (Tools > Analyze Xdebug Profiler Snapshot).
- Corral writes the files uncompressed, so all of these tools can read them.

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
- **Mail**: turn on "Catch mail on 127.0.0.1:2525". Corral receives each message that a site sends with SMTP to this address, and keeps the newest 1000. Select a message and press Space to preview it, or double-click it. Delete moves it to the Trash. For a Laravel or WordPress site, click "Send Mail to Corral" in the site menu, or run `corral mail:use` in the site folder. The menu item also turns on mail capture.
  - Laravel: Corral changes the `MAIL_` values in `.env`, and keeps the original file as `.env.corral.bak`.
  - WordPress: Corral adds the must-use plugin `wp-content/mu-plugins/corral-mail.php`. It sends every `wp_mail()` to Corral, also when an SMTP plugin is active. Delete the file to send mail as before.
  - The site name is the inbox, so you can see which site sent a message.

  In a terminal, `corral mail` lists the messages, `corral mail:links` prints the links of the newest one, and `corral mail:attachments` saves its attachments. In a test, `corral mail:wait <inbox>` waits until the site sends the next message.
- **Requests**: turn on "Record requests", or run `corral queries on`. Each request of a Laravel or WordPress site then records its SQL queries (with the time and the code that ran each one) and its outgoing HTTP calls (with status and time). Laravel sites also record cache events (hits, misses, writes, deletes, grouped by key) and queue events (jobs queued, and jobs that run or fail in the request). Insights shows the newest 200 requests, marks queries slower than 100 ms and HTTP calls slower than 1 s, and counts repeated queries (often an N+1 problem). `corral queries:list [n]` prints the newest `n` requests. Queue workers (`php artisan queue:work`) run outside PHP-FPM, so Corral does not record the jobs that they run.

How the recording works:

- Corral adds `auto_prepend_file` to each PHP-FPM pool. The file runs before the site's code.
- In Laravel, it listens for the query, HTTP client, cache, and queue events. In WordPress, it turns on `SAVEQUERIES` and reads `$wpdb->queries` at the end of the request, and it adds the `pre_http_request` and `http_api_debug` hooks before WordPress loads.
- Each request with something to show adds one line to `logs/queries.jsonl` in Corral's folder. The file starts again at 20 MB.
- Other PHP code records nothing. A site that sets its own `auto_prepend_file` (for example in `.user.ini`) keeps it, and records nothing.
- If `wp-config.php` defines `SAVEQUERIES`, Corral uses that value and does not define the constant itself. With `false`, Corral records no queries for that site.

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

### Bundled tools

`Corral.app` includes Composer, WP-CLI, and the Laravel installer as PHP archives (phars). Corral writes the commands `composer`, `wp`, and `laravel` to its `bin` folder. They run on the global PHP version, so they need at least one installed PHP. Run `corral tools` to see their versions.

- **Composer and WP-CLI:** the build downloads a pinned version of each and checks its SHA-256.
- **Laravel installer:** a GitHub workflow (`.github/workflows/tools.yml`) builds it into one phar with Box, as Herd does. It publishes the phar to the `tools` release with its SHA-256. The app build bundles the newest one. If the release does not exist yet, the app builds without it.

Settings > Tools and `corral tools:update [composer|wp|laravel]` fetch a newer version. The app checks the SHA-256 from the publisher before it installs the file. Composer and WP-CLI come from their own sites. The Laravel installer comes from the `tools` release. The new copy goes to Corral's `tools` folder. The commands use it in place of the copy inside the app. `corral laravel:update` is the same as `corral tools:update laravel`.

The `wp` command hides PHP deprecation notices, because WP-CLI 2.12 prints some of its own on PHP 8.5.

### WordPress setup

Run `corral wp:setup [name]` in a folder that holds a WordPress project, for example a clone that tracks only `wp-content`.
The name defaults to the folder name. The command uses Corral's own `wp` (WP-CLI) and `php`. It does not need the `mysql` client.

1. Serve the folder as `<name>.test` over HTTPS.
2. Create the database `wp_<name>` on the MySQL server at `127.0.0.1`, with Corral's PHP (`mysqli`). The user is `root`, with no password.
3. Download WordPress core with `wp core download --skip-content`. Corral skips this step when `wp-load.php` exists.
4. Create `wp-config.php`. Corral skips this step when the file exists.
5. Install WordPress with the user `admin` and the password `admin`, in the locale `en_US`. Change these values in Settings > Tools > New WordPress sites, or with `corral wp:defaults`.
6. Turn on `WP_DEBUG`, `WP_DEBUG_LOG`, `WP_DEBUG_DISPLAY`, `SCRIPT_DEBUG`, and `DISABLE_WP_CRON`, and set `ENVIRONMENT` to `DEV`.
7. Open `/wp-admin` in the browser.

Use this command for local development only. The admin password is not secret.

`corral wp:defaults` changes the values for new sites, for example:

```sh
corral wp:defaults --user dev --password dev --email dev@example.com --locale sv_SE --prefix wp_
```

Without options, the command shows the values. An empty email means `admin@<site>.test`.
The database name is always `wp_<name>`, whatever the table prefix is.

The panel runs the same steps. Open the site's "..." menu and choose "Set Up WordPress". The entry shows only for a site that has `wp-content` or `wp-load.php` but no `wp-config.php`.
If a step fails, the panel shows the end of its output.

#### Import a database

After a clone, the site usually needs the database from production or staging.
Export it there, for example with `wp db export`, then run this in the site folder:

```sh
corral wp:import ~/Downloads/shop.sql.gz
```

1. Corral reads the connection from `wp-config.php`. It creates the database when it does not exist.
2. Corral imports the dump (`.sql` or `.sql.gz`) with its own PHP (`mysqli`). It does not need the `mysql` client.
3. Corral reads `siteurl` from the imported data, and replaces the old address with `https://<name>.test` in all tables with the WordPress table prefix. It uses `wp search-replace`, which also changes serialized data. It does not change the `guid` column.

The tables in the dump replace the tables in the database. In the panel, choose "Import Database…" in the site's "..." menu. The entry shows for a site with `wp-config.php`.
Corral cannot import a dump with `DELIMITER` blocks (stored procedures). Use the `mysql` client for such a file.

### Laravel setup

Run `corral laravel:setup [name]` in a fresh clone of a Laravel project.
The name defaults to the folder name. The command uses Corral's own `composer` and `php`. It creates the database with `mysqli`, so it does not need the `mysql` client.

1. Serve the folder as `<name>.test` over HTTPS.
2. Run `composer install` when the `vendor` folder is missing.
3. Copy `.env.example` to `.env`. Set `APP_URL` to the HTTPS address, and set `DB_*` to a local MySQL database. The database name is the site name, with `_` in place of dots and dashes. The user is `root`, with no password.
4. Run `php artisan key:generate`, create the database, and run `php artisan migrate`. Add `--seed` to seed the database.
5. Run `npm install` and `npm run build` when `package.json` exists.
6. Open the site in the browser.

In the panel, choose "Set Up Laravel" in the site's "..." menu. The entry shows for a site that has `artisan` and lacks a `.env` or a `vendor` folder. The panel does not seed the database.

If the folder already has a `.env`, Corral does not change it. In this case the command runs only `composer install` and the npm build, because the file can point to a database that Corral must not change.
For WordPress sites, Corral adds the nginx rules for multisite in subdirectories.
Multisite with subdomains also works, because each site answers `*.<site>.test`.

### New Laravel projects

Run `corral new <name>` to create a Laravel project with the bundled Laravel installer.

1. Corral runs `laravel new <name>` in the current folder if it is parked, else in the first parked folder (`~/Corral` by default). The installer asks for the starter kit, the database, and the other choices.
2. Corral serves the project at `https://<name>.test`, and sets `APP_URL` in `.env` to that address.
3. Corral opens the site in the browser.

Options after the name go to the installer, for example `corral new shop --vue --database=mysql`.
Corral adds `--no-boost`, because Laravel Boost is an AI add-on. Pass `--boost` to install it.

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

You can run the same check later with `corral check`.

The menu bar app shows the same steps when it finds Herd. The "..." menu also has "Move from Herd…".
Corral reads the Herd files and does not change them. Corral does not manage Node.js versions.

To use Herd again, run this command, then start Herd:

```sh
corral migrate:herd --undo
```

### Uninstall Herd

After the move, run `corral uninstall:herd --dry-run` to see what goes, then `corral uninstall:herd`.
In the panel, choose "Uninstall Herd…" in the "..." menu. The entry shows when Corral serves `.test` and `/Applications/Herd.app` exists.

The steps follow Herd's own uninstall script (`Herd.app/Contents/Resources/uninstall`) and Herd's docs page "Uninstalling":

1. Quit Herd, and stop Herd's processes.
2. Remove Herd's privileged helper, its LaunchDaemon, and `/etc/sudoers.d/herd`. This needs your password once.
3. Remove `/etc/resolver/test` only when it is Herd's file. When it sends `.test` to Corral, it stays.
4. Remove Herd from the login items, and remove Herd's lines from `~/.zshrc`, `~/.bashrc`, and `~/.bash_profile`. Corral keeps a copy of each changed file as `<file>.corral-herd.bak`.
5. Delete Herd's settings (`defaults delete de.beyondco.herd`).
6. Move `~/Library/Application Support/Herd` and `Herd.app` to the Trash. Corral does not delete them, so you can get them back until you empty the Trash.

Read the list before you confirm:

- Herd Pro databases and storage are in `config/services` in Herd's folder. When this folder has data, Corral asks again. `--yes` alone does not accept it. Export the data first, or pass `--include-services`.
- Herd's folder also holds Herd's nvm, with its Node.js versions and global npm packages. Corral moves it to `~/.nvm` first, and adds the standard nvm lines to the shell file. When Herd's shell file switched Node from `.nvmrc`, Corral adds nvm's hook that does the same. If `~/.nvm` exists already, Corral does not touch it, and Herd's Node versions go to the Trash with the folder. (`herd isolate-node` only writes `.nvmrc` files in your projects, so those stay.)
- The "Laravel Valet CA" stays in the System keychain unless you agree, or pass `--remove-ca`. Laravel Valet uses the same CA.
- After this step, `corral migrate:herd --undo` no longer works.

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

`corral run` does the same for one command, with no port to choose.
Corral picks a free port, sets `PORT`, and serves the app at `https://<folder>.test` until the command stops.
Then it removes the proxy again. If a PHP site has the same name, that site comes back.

```sh
cd ~/Code/shop
corral run npm run dev
```

- Use `--name` to choose another name than the folder name.
- Vite and Astro do not read `PORT`. Corral adds `--port` and `--host 127.0.0.1` to `vite` and `astro dev`, also when a `package.json` script (`npm run dev`) runs them. Corral prints the flags that it adds.
- Use `--port` for another server that does not read `PORT`, and give the same port to the server: `corral run --port 8000 python3 -m http.server 8000`.
- A server can listen on `127.0.0.1` or only on `::1`. nginx tries `127.0.0.1` first, then `::1`.
- If the `corral run` process is killed (`kill -9`), it cannot remove its proxy. The menu bar app removes it within 15 seconds, and `corral start` removes it too.
- Next.js 15.2 and later allow hot reload only from `localhost` origins. For the `/_next` paths of a proxy site, Corral sends a `localhost` origin when the page comes from the site itself. You do not need `allowedDevOrigins`.

[portless](https://github.com/vercel-labs/portless) gives each app a name such as `shop.localhost`.
If Laravel Herd uses ports 80 and 443, portless must use a different port, for example 1355.
Corral can serve the same app without a port:

```sh
corral proxy shop https://shop.localhost:1355
```

Then open `http://shop.test`.
If Herd has `.test`, give Corral a second TLD, for example `internal`, and open `http://shop.internal`.
For `.localhost` URLs, Corral connects to `127.0.0.1` (or `::1`) and sends the original name.
portless needs the name to select the app.

Corral also lists the apps that portless serves.
The panel shows them in a "portless" section, and `corral sites` prints them with the word `portless`.
Click an app to open its address.
Corral reads the route file `~/.portless/routes.json` (or the folder in `PORTLESS_STATE_DIR`) and the proxy settings next to it.
It does not start portless, and it does not serve these apps.
It hides an app when its process has stopped.

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
| `bin/` | `php` (global version), `php84`-style commands for each version, `composer`, `wp`, and `laravel` |
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

- Corral does not include Node.js.
- Corral has special rules for WordPress only. Use `.corral.json` for frameworks such as Magento.
- Corral does not manage databases.
- Insights does not show database queries.
- The debug pool does not detect an editor that is listening. Use the browser extension or a query argument.
- Xdebug profiling is not set up yet.

## Documentation

- [How Corral works](docs/architecture.md)
- [Contributing](CONTRIBUTING.md)
- [Changelog](CHANGELOG.md)

## License

Corral is available under the [MIT License](LICENSE).

`Corral.app` includes nginx, OpenSSL, PCRE2, zlib, dnsmasq, Composer, WP-CLI, and the Laravel installer.
Their licenses are in `Corral.app/Contents/Resources/licenses/`.
dnsmasq is GPL software. Its source code is in the same folder.
