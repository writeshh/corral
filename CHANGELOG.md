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
