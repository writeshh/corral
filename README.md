# Corral

Corral is a local PHP development environment for macOS.
It serves each project folder at its own domain, for example `http://blog.internal`.
Corral is a menu bar app and a command-line tool in one binary.

Corral does not collect telemetry. It does not send data to any server.

## Features

- Serve every subfolder of a "parked" folder as `<folder>.internal`.
- Link a single folder to a domain name.
- Serve sites over HTTPS with certificates from a local certificate authority (CA).
- Use one global PHP version, or pin a different version to a site.
- Answer subdomains, for example `api.blog.internal`.
- Control everything from the menu bar or from the `corral` command.
- Run next to Laravel Herd without conflicts.

## Requirements

- macOS 14 or later
- Apple silicon (Corral looks for Homebrew in `/opt/homebrew`)
- Homebrew
- Xcode or the Xcode Command Line Tools, to build Corral

## Installation

1. Install the dependencies:

   ```sh
   brew install php nginx dnsmasq
   ```

2. Build the app:

   ```sh
   ./bundle.sh
   ```

3. Add the `corral` command to your path:

   ```sh
   ln -s "$PWD/Corral.app/Contents/MacOS/Corral" /opt/homebrew/bin/corral
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
| `corral sites` | List all sites with their URL, PHP version, and document root. |
| `corral secure [site]` | Serve a site over HTTPS. |
| `corral unsecure [site]` | Serve a site over HTTP. |
| `corral use <version>` | Set the global PHP version, for example `8.4`. |
| `corral isolate <version> [site]` | Pin a PHP version to one site. |
| `corral unisolate [site]` | Use the global PHP version for a site again. |
| `corral php:list` | List the installed PHP versions. |
| `corral open [site]` | Open a site in the browser. |
| `corral start` | Start nginx, dnsmasq, and PHP-FPM. |
| `corral stop` | Stop all services. |
| `corral restart` | Stop and start all services. |
| `corral status` | Show the state of each service. |
| `corral trust` | Add the local CA to your login keychain. |
| `corral install` | Configure DNS and ports 80 and 443. |
| `corral uninstall` | Remove the system configuration. |

If you do not give a site name, Corral uses the site in the current folder.

To install more PHP versions, use Homebrew, for example `brew install php@8.3`.

## Document root

If a site folder contains a `public` folder, Corral serves the `public` folder.
If not, Corral serves the site folder.
Corral sends requests for missing files to `index.php`.
This works for Laravel, Symfony, and most other PHP frameworks.

## Configuration

Corral keeps its state in `~/Library/Application Support/Corral`:

| Path | Contents |
|---|---|
| `config.json` | Parked folders, links, secured sites, and PHP versions |
| `conf/` | Generated nginx and PHP-FPM configuration |
| `run/` | Process IDs and PHP-FPM sockets |
| `logs/` | nginx and PHP-FPM logs |
| `certs/` | Local CA and site certificates |

You can change the domain suffix with the `tld` key in `config.json`.
After a change, run `corral uninstall` and `corral install` again.

These environment variables change the defaults:

| Variable | Effect |
|---|---|
| `CORRAL_HOME` | Use a different state folder. Keep the path short. Socket paths must be shorter than 104 bytes. |
| `CORRAL_NGINX` | Use a different nginx binary. |
| `CORRAL_DNSMASQ` | Use a different dnsmasq binary. |
| `HOMEBREW_PREFIX` | Look for Homebrew in a different folder. |

## Uninstall

1. Stop the services and remove the system configuration:

   ```sh
   corral uninstall
   ```

2. Remove the local CA from the login keychain. Use the Keychain Access app and search for "Corral Local CA".
3. Delete `~/Library/Application Support/Corral`.
4. Delete `Corral.app` and the `corral` link.

## Limitations

- Corral does not include nginx, dnsmasq, or PHP. You must install them with Homebrew.
- Corral does not have framework-specific drivers. Subdirectory WordPress multisite does not work.
- Corral does not manage databases, mail, or Node.js versions.

## Documentation

- [How Corral works](docs/architecture.md)
- [Contributing](CONTRIBUTING.md)
- [Changelog](CHANGELOG.md)
