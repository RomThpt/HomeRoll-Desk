# HomeRoll Desktop Local

Native macOS client for a private Immich server. This fork is based on [HomeRoll Desktop](https://github.com/silentprovider423/HomeRoll-Desk) by silentprovider423, revision `8c71e2094001d59c282a83f2a7f750869a7b6c9e`.

## Safety changes

- Imports capture one server/account/client. Account or permission changes revoke them and cancel their network requests.
- Disabling automatic Photos sync cancels active work and delayed retries. PhotoKit may finish extracting its current resource locally, but that cancelled operation cannot start another upload.
- Original images/videos, Live Photo paired video, alternate images and available rendered edits are transferred. Missing required resources remain pending rather than being reported as already imported.
- Progress uses account-scoped, revision-aware receipts. Server checksums, trash state and Live Photo linkage are checked before success and again on subsequent syncs. Old UUID-only completion markers are not trusted.
- Login tokens stay in the macOS Keychain. This fork uses separate bundle identifiers and does not read upstream plaintext credential files. Sign in again when moving from upstream.
- Remote updater removed, including its Debug bypass. No executable downloads or quarantine removal. Updates require reviewing source and rebuilding.
- View-only accounts cannot create share links. Authentication headers and redirects are restricted to the selected origin.
- Decoded image responses are checked against the current session; Live Photo disk caches are separated by session and use hashed filenames.

These controls do not replace an independent backup or restore test. Receipts compare Immich's asset metadata to local hashes, not a complete download/restore of every original. Apple-specific editing recipes, albums and complete Photos database restoration are not supported; original and rendered media are preserved. Originals in Apple Photos are never removed.

## Build and tests

Requires macOS 15+, Xcode and an existing XcodeGen installation. No third-party runtime packages are fetched.

```sh
xcodegen generate
xcodebuild -project HomeRollDesktop.xcodeproj -scheme HomeRollDesktop -configuration Release -derivedDataPath build CODE_SIGN_IDENTITY=- build
xcodebuild -project HomeRollDesktop.xcodeproj -scheme HomeRollDesktop -destination 'platform=macOS,arch=arm64' -derivedDataPath build CODE_SIGN_IDENTITY=- test
```

Tests use dummy credentials and URLProtocol fixtures. `HOMEROLL_TESTING=1` suppresses normal startup in the test host. Do not run upstream `FOTOS_SELFTEST` against a real server: it mutates server data.

`build-app.sh` packages a local build. Set `HOMEROLL_SIGNING_IDENTITY` to a local signing identity for stable Keychain access across builds; the default ad hoc signature may require renewed access approval after rebuilding. No automatic installation or publication takes place.

The generated application is `build/Build/Products/Release/HomeRoll Desktop Local.app`. Open it and enter the private server URL and your Immich account. Automatic Photos imports are off until enabled in Settings. Tailscale must be connected when the server is accessible only through that network.

A private default server address can be placed in `HomeRollDefaultServerURL` in an ignored `project.local.yml` copy, generated using `xcodegen generate --spec project.local.yml`. Never commit tokens, private server addresses, signing identities or personal media.

## Privacy and scope

The client contacts the selected Immich server, the configured identity provider for SSO and Apple services when using Maps or downloading Photos resources stored in iCloud. No GitHub update checks or analytics are present in this fork. Optional upstream helper services on different ports are rejected by the same-origin credential policy.

Source review and synthetic tests do not certify a downloaded upstream binary or validate every PhotoKit behavior on a real library. Use this fork's locally built application.

## License

[GPL-3.0](LICENSE). Immich is a separate server and is not distributed here. Original source attribution is retained in Git history.
