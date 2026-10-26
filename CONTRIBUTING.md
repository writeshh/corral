# Contributing

## Build and test

1. Build the debug binary:

   ```sh
   swift build
   ```

2. Run the tests:

   ```sh
   swift test
   ```

3. Build `Corral.app`. The first build also runs `scripts/build-deps.sh`, which compiles nginx and dnsmasq into `.deps/`.

   ```sh
   ./bundle.sh
   ```

To update nginx, dnsmasq, or their libraries, change the version and the SHA-256 checksum in `scripts/build-deps.sh`.
Then delete `.deps/` and run `./bundle.sh` again.

To test without changes to your real configuration, set `CORRAL_HOME` to a short temporary path.

## Rules

- Do not add telemetry, analytics, or crash reporting.
- Do not add network calls that the user did not request.
- Keep root access in `corral install` and `corral uninstall` only.

## Writing style

Write documentation and code comments in ASD-STE100 Simplified Technical English:

- Use short, common words.
- Use active voice.
- Write one instruction per sentence.
- Do not use semicolons.

## Commit messages

Use [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/#specification).

- Write the header as `<type>[optional scope]: <description>`.
- Use one of these types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`.
- Write the description in the imperative mood, in lowercase, with no period at the end.
- Keep the header at 50 characters or fewer.
- Wrap body lines at 72 characters. Use the body to explain why the change is necessary.
- Mark breaking changes with `!` or a `BREAKING CHANGE:` footer.
- Make each commit one logical change. The project must build at each commit.

Examples:

```
feat(cli): add php:list command
fix(nginx): wait for reload before return
docs: correct install steps in README
```

## Changelog

Add each user-visible change to the `Unreleased` section of [CHANGELOG.md](CHANGELOG.md).
